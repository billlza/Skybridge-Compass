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

    #if DEBUG || SKYBRIDGE_BENCHMARKING
    private static let deterministicNonceLock = NSLock()
    private nonisolated(unsafe) static var deterministicNonceCounter: UInt64 = 0
    #endif
    private nonisolated static let appleXWingAvailable: Bool = {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleXWingCryptoProvider.selfTest()
        }
        #endif
        return false
    }()

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

    private let kemIdentityStore: any HandshakeKEMIdentityStore

 /// 对端 KEM 身份公钥（按套件）
    private let peerKEMPublicKeys: [CryptoSuite: Data]

 /// 临时私钥（按套件存储）
    private var keyExchangePrivateKeys: [CryptoSuite: SecureBytes] = [:]

 /// v2 发起方临时贡献私钥（X25519）
    private var v2InitiatorContributionPrivateKey: SecureBytes?

 /// v2 响应方看到的发起方临时贡献公钥（X25519）
    private var v2PeerInitiatorContribution: Data?

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

    /// 最近一次成功验签得到的远端协议身份 authority
    private var authenticatedRemoteAuthority: AuthenticatedRemoteAuthority?

    /// Invalidates suspended actor work after cancellation/zeroization. Actor
    /// isolation alone is re-entrant across `await`, so every network-message
    /// operation verifies this generation before committing resumed results.
    private var lifecycleGeneration: UInt64 = 0
    private var isProcessingHandshakeMessage = false

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
        kemIdentityStore: any HandshakeKEMIdentityStore,
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
        self.kemIdentityStore = kemIdentityStore
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
        kemIdentityStore: (any HandshakeKEMIdentityStore)? = nil,
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
            if cryptoProvider.tier == .nativePQC, Self.appleXWingAvailable {
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
            kemIdentityStore: kemIdentityStore ?? DefaultHandshakeKEMIdentityStore(),
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
        provider: any CryptoProvider,
        generation: UInt64? = nil
    ) async throws {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        if keyExchangePrivateKeys[suite] != nil {
            return
        }

        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        if let generation {
            try ensureActive(generation: generation)
        }

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
        guard Self.fillRandomBytes(&nonceBytes, label: 0x41) else {
            throw HandshakeError.failed(.cryptoError("Failed to generate nonce"))
        }

        nonce = SecureBytes(data: Data(nonceBytes))
    }

    public func getAuthenticatedRemoteAuthority() -> AuthenticatedRemoteAuthority? {
        authenticatedRemoteAuthority
    }

    /// Atomically snapshots diagnostics metadata and invalidates all handshake
    /// state. Drivers use this at the terminal failure boundary so an SOA or
    /// transport rejection cannot retain KEM secrets in a detached context.
    func invalidateAndTakeNegotiatedSuite() -> CryptoSuite? {
        let suite = negotiatedSuite
        zeroize()
        return suite
    }

    private func makeAuthenticatedRemoteAuthority(
        from identityKeys: IdentityPublicKeys
    ) throws -> AuthenticatedRemoteAuthority {
        guard let protocolSigningAlgorithm = ProtocolSigningAlgorithm(from: identityKeys.protocolAlgorithm) else {
            throw HandshakeError.failed(
                .invalidMessageFormat("Unsupported protocol signing algorithm: \(identityKeys.protocolAlgorithm.rawValue)")
            )
        }

        return AuthenticatedRemoteAuthority(
            protocolSigningAlgorithm: protocolSigningAlgorithm,
            protocolPublicKeyFingerprint: try identityKeys.authoritativeProtocolFingerprint().lowercased()
        )
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
        offeredSuites: [CryptoSuite]? = nil,
        extensionsRaw: Data = Data()
    ) async throws -> HandshakeMessageA {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        guard role == .initiator else {
            throw HandshakeError.invalidState("Only initiator can build MessageA")
        }

        guard !isProcessingHandshakeMessage else {
            throw HandshakeError.invalidState("Another handshake operation is already in progress")
        }
        isProcessingHandshakeMessage = true
        let generation = lifecycleGeneration
        var completed = false
        defer {
            isProcessingHandshakeMessage = false
            if !completed {
                zeroize()
            }
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
        let messageACapabilities = Self.advertisedCapabilities(
            localCapabilities,
            for: supportedSuites
        )
        var keyShares: [HandshakeKeyShare] = []
        var sentKeyShares: [CryptoSuite: Data] = [:]

        for suite in supportedSuites {
            guard let provider = providerForSuite(suite) else {
                continue
            }
            if suite.isPQC {
                guard let peerKEMPublicKey = peerKEMPublicKey(for: suite) else {
                    continue
                }
                let encapsResult: (encapsulatedKey: Data, sharedSecret: SecureBytes)
                if suite == .qperiaptABI2PolicyBound {
                    guard let policyBoundProvider = provider as? any ApplicationContextBoundCryptoProvider else {
                        throw HandshakeError.invalidState(
                            "Q-Periapt ABI2 provider does not expose its application-context contract"
                        )
                    }
                    let applicationContext = try QPeriaptHandshakeApplicationContext.messageA(
                        version: HandshakeConstants.protocolVersion,
                        suite: suite,
                        clientNonce: nonceData,
                        recipientPublicKey: peerKEMPublicKey,
                        policy: policy,
                        offeredSuites: supportedSuites,
                        capabilities: messageACapabilities,
                        identityPublicKey: identityPublicKey,
                        extensionsRaw: extensionsRaw
                    )
                    encapsResult = try await policyBoundProvider.kemEncapsulate(
                        recipientPublicKey: peerKEMPublicKey,
                        applicationContext: applicationContext
                    )
                } else {
                    encapsResult = try await provider.kemEncapsulate(
                        recipientPublicKey: peerKEMPublicKey
                    )
                }
                try ensureActive(generation: generation)
                keyShares.append(HandshakeKeyShare(suite: suite, shareBytes: encapsResult.encapsulatedKey))
                sentKeyShares[suite] = encapsResult.encapsulatedKey
                kemSharedSecrets[suite] = encapsResult.sharedSecret
            } else {
                try await generateEphemeralKeyPair(
                    for: suite,
                    provider: provider,
                    generation: generation
                )
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

        let initiatorContribution: Data?
        if supportedSuites.contains(where: { $0.requiresV2EphemeralContribution }) {
            initiatorContribution = try generateV2InitiatorContribution()
        } else {
            v2InitiatorContributionPrivateKey?.zeroize()
            v2InitiatorContributionPrivateKey = nil
            initiatorContribution = nil
        }

        let messageA = HandshakeMessageA(
            version: HandshakeConstants.protocolVersion,
            supportedSuites: supportedSuites,
            keyShares: keyShares,
            clientNonce: nonceData,
            policy: policy,
            capabilities: messageACapabilities,
            signature: Data(),
            identityPublicKey: identityPublicKey,
            extensionsRaw: extensionsRaw,
            initiatorContribution: initiatorContribution
        )

 // 14.2: 构建待签名数据（包含域分离前缀）
        let dataToSign = messageA.signaturePreimage

 // 计算 transcriptA
        let transcriptA = SHA256.hash(data: messageA.transcriptBytes)
        transcriptHashA = SecureBytes(data: Data(transcriptA))

        // 签名
        let signature = try await signHandshakeData(dataToSign, identityKeyHandle: identityKeyHandle)
        try ensureActive(generation: generation)
#if DEBUG || SKYBRIDGE_TESTING
        if ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil {
            let suiteSummary = supportedSuites.map(\.rawValue).joined(separator: ",")
            let preimageDigest = SHA256.hash(data: dataToSign).map { String(format: "%02x", $0) }.joined().prefix(16)
            let identitySummary = (try? IdentityPublicKeys.decodeWithLegacyFallback(from: identityPublicKey))
            let smokeMessage =
                "🧪 mac tx MessageA suites=\(suiteSummary) " +
                "sigAlg=\(identitySummary?.protocolAlgorithm.rawValue ?? "unknown") " +
                "pubBytes=\(identitySummary?.protocolPublicKey.count ?? identityPublicKey.count) " +
                "sigBytes=\(signature.count) " +
                "preimageSha256=\(preimageDigest)"
            SkyBridgeLogger.p2p.info("\(smokeMessage, privacy: .public)")
        }
#endif
        let seSigPreimage = messageA.secureEnclaveSignaturePreimage
        var seSignature: Data?
        if policy.requireSecureEnclavePoP, secureEnclaveKeyHandle == nil {
            throw HandshakeError.failed(.secureEnclavePoPRequired)
        }
        do {
            seSignature = try await signSecureEnclaveData(seSigPreimage, secureEnclaveKeyHandle: secureEnclaveKeyHandle)
            try ensureActive(generation: generation)
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
        try ensureActive(generation: generation)

        self.sentSupportedSuites = supportedSuites
        self.sentKeyShares = sentKeyShares

        let signedMessage = HandshakeMessageA(
            version: messageA.version,
            supportedSuites: messageA.supportedSuites,
            keyShares: messageA.keyShares,
            clientNonce: messageA.clientNonce,
            policy: messageA.policy,
            capabilities: messageA.capabilities,
            signature: signature,
            identityPublicKey: messageA.identityPublicKey,
            extensionsRaw: messageA.extensionsRaw,
            secureEnclaveSignature: seSignature,
            initiatorContribution: messageA.initiatorContribution
        )
        completed = true
        return signedMessage
    }

    private static func advertisedCapabilities(
        _ capabilities: CryptoCapabilities,
        for supportedSuites: [CryptoSuite]
    ) -> CryptoCapabilities {
        guard supportedSuites.contains(.qperiaptABI2PolicyBound) else {
            return capabilities
        }

        return CryptoCapabilities(
            supportedKEM: prependIfMissing(
                P2PCryptoAlgorithm.qperiaptABI2PolicyBound.rawValue,
                to: capabilities.supportedKEM
            ),
            supportedSignature: prependIfMissing(
                P2PCryptoAlgorithm.mlDSA65.rawValue,
                to: capabilities.supportedSignature
            ),
            supportedAuthProfiles: prependIfMissing(
                QPeriaptPlatformPolicy.authProfile,
                to: capabilities.supportedAuthProfiles
            ),
            supportedAEAD: capabilities.supportedAEAD,
            pqcAvailable: true,
            platformVersion: capabilities.platformVersion,
            providerType: .qPeriapt
        )
    }

    private static func prependIfMissing(_ value: String, to values: [String]) -> [String] {
        if values.contains(value) {
            return values
        }
        return [value] + values
    }

    private static func decodeResponderCapabilities(from payload: Data) throws -> CryptoCapabilities {
        do {
            var decoder = ResponderCapabilityPayloadDecoder(data: payload)
            let capabilities = try decoder.decode()
            guard try capabilities.deterministicEncode() == payload else {
                throw ResponderCapabilityPayloadError.nonCanonicalEncoding
            }
            return capabilities
        } catch {
            throw HandshakeError.failed(
                .invalidMessageFormat("Responder capabilities payload is invalid or non-canonical")
            )
        }
    }

    private func validateResponderCapabilities(
        _ capabilities: CryptoCapabilities,
        selectedSuite: CryptoSuite,
        policy: HandshakePolicy
    ) throws {
        guard selectedSuite.isNegotiable,
              suiteMeetsHandshakePolicy(selectedSuite, policy: policy) else {
            throw Self.responderCapabilityBindingFailure("selected suite violates the local handshake policy")
        }

        guard Self.capabilityValuesAreCanonicalAndUnique(capabilities.supportedKEM),
              Self.capabilityValuesAreCanonicalAndUnique(capabilities.supportedSignature),
              Self.capabilityValuesAreCanonicalAndUnique(capabilities.supportedAuthProfiles),
              Self.capabilityValuesAreCanonicalAndUnique(capabilities.supportedAEAD) else {
            throw Self.responderCapabilityBindingFailure("capability sets contain empty or duplicate values")
        }

        let requiredKEM: String
        switch selectedSuite.wireId {
        case CryptoSuite.xwingMLDSA.wireId:
            requiredKEM = P2PCryptoAlgorithm.xWing.rawValue
        case CryptoSuite.qperiaptABI2PolicyBound.wireId:
            requiredKEM = P2PCryptoAlgorithm.qperiaptABI2PolicyBound.rawValue
        case CryptoSuite.mlkem768MLDSA65.wireId,
             CryptoSuite.mlkem768MLDSA65FS.wireId:
            requiredKEM = P2PCryptoAlgorithm.mlKEM768.rawValue
        case CryptoSuite.x25519Ed25519.wireId:
            requiredKEM = P2PCryptoAlgorithm.x25519.rawValue
        case CryptoSuite.p256ECDSA.wireId:
            requiredKEM = P2PCryptoAlgorithm.p256.rawValue
        default:
            throw Self.responderCapabilityBindingFailure("selected suite has no capability mapping")
        }

        guard Self.containsCanonicalCapability(requiredKEM, in: capabilities.supportedKEM),
              Self.containsCanonicalCapability(
                P2PCryptoAlgorithm.aes256GCM.rawValue,
                in: capabilities.supportedAEAD
              ) else {
            throw Self.responderCapabilityBindingFailure("selected suite or payload AEAD was not advertised")
        }

        if selectedSuite == .qperiaptABI2PolicyBound {
            guard QPeriaptPlatformPolicy.isHandshakePeerEligible(capabilities) else {
                throw Self.responderCapabilityBindingFailure(
                    "Q-Periapt ABI2 signed-policy capability binding is invalid"
                )
            }
            return
        }

        let requiredAuthProfile: String
        if selectedSuite.isHybrid {
            requiredAuthProfile = AuthProfile.hybrid.displayName
        } else if selectedSuite.isPQC {
            requiredAuthProfile = AuthProfile.pqc.displayName
        } else {
            requiredAuthProfile = AuthProfile.classic.displayName
        }
        guard Self.containsCanonicalCapability(
            requiredAuthProfile,
            in: capabilities.supportedAuthProfiles
        ) else {
            throw Self.responderCapabilityBindingFailure("selected suite authentication profile was not advertised")
        }

        if selectedSuite.isPQC {
            guard capabilities.pqcAvailable,
                  capabilities.providerType == .cryptoKitPQC
                    || capabilities.providerType == .liboqs else {
                throw Self.responderCapabilityBindingFailure(
                    "selected PQC suite contradicts the responder provider capability"
                )
            }
        }
    }

    private static func containsCanonicalCapability(_ required: String, in values: [String]) -> Bool {
        let canonicalRequired = canonicalCapabilityToken(required)
        return values.contains { canonicalCapabilityToken($0) == canonicalRequired }
    }

    private static func capabilityValuesAreCanonicalAndUnique(_ values: [String]) -> Bool {
        let canonicalValues = values.map(canonicalCapabilityToken)
        return canonicalValues.allSatisfy { !$0.isEmpty }
            && Set(canonicalValues).count == canonicalValues.count
    }

    private static func canonicalCapabilityToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
    }

    private static func responderCapabilityBindingFailure(_ reason: String) -> HandshakeError {
        .failed(.invalidMessageFormat("Responder capabilities do not match MessageB: \(reason)"))
    }

    private func ensureActive(generation: UInt64) throws {
        guard !isZeroized, lifecycleGeneration == generation else {
            throw HandshakeError.contextZeroized
        }
    }

    private static func validatedMessageAKeyShares(
        _ messageA: HandshakeMessageA
    ) throws -> [CryptoSuite: Data] {
        guard messageA.version == HandshakeConstants.protocolVersion else {
            throw HandshakeError.failed(.versionMismatch(
                local: HandshakeConstants.protocolVersion,
                remote: messageA.version
            ))
        }
        guard messageA.clientNonce.count == 32 else {
            throw HandshakeError.failed(.invalidMessageFormat("Invalid MessageA nonce length"))
        }
        guard !messageA.supportedSuites.isEmpty,
              messageA.supportedSuites.count <= Int(HandshakeConstants.maxSupportedSuites),
              messageA.supportedSuites.allSatisfy(\.isNegotiable),
              Set(messageA.supportedSuites.map(\.wireId)).count == messageA.supportedSuites.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Invalid or duplicate supported suite"))
        }
        guard messageA.keyShares.count <= Int(HandshakeConstants.maxKeyShareCount),
              messageA.keyShares.count <= messageA.supportedSuites.count else {
            throw HandshakeError.failed(.invalidMessageFormat("Invalid MessageA keyShare count"))
        }

        let supportedIndexes = Dictionary(
            uniqueKeysWithValues: messageA.supportedSuites.enumerated().map { ($0.element.wireId, $0.offset) }
        )
        var previousIndex = -1
        var result: [CryptoSuite: Data] = [:]
        result.reserveCapacity(messageA.keyShares.count)
        for keyShare in messageA.keyShares {
            guard keyShare.suite.isNegotiable,
                  let index = supportedIndexes[keyShare.suite.wireId],
                  index >= previousIndex else {
                throw HandshakeError.failed(
                    .invalidMessageFormat("MessageA keyShares are unsupported or out of order")
                )
            }
            guard result.updateValue(keyShare.shareBytes, forKey: keyShare.suite) == nil else {
                throw HandshakeError.failed(.invalidMessageFormat("Duplicate keyShare suite"))
            }
            previousIndex = index
        }
        return result
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
        postSignatureValidation: (@Sendable (IdentityPublicKeys) async throws -> Void)? = nil,
        secureEnclavePublicKey: Data? = nil,
        rawSignaturePreimage: Data? = nil
    ) async throws {
        RemoteControlSmokeStatusWriter.append("mac-handshake processA begin")
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        guard role == .responder else {
            throw HandshakeError.invalidState("Only responder can process MessageA")
        }

        guard !isProcessingHandshakeMessage else {
            throw HandshakeError.invalidState("A handshake message is already being processed")
        }
        isProcessingHandshakeMessage = true
        let generation = lifecycleGeneration
        var completed = false
        defer {
            isProcessingHandshakeMessage = false
            if !completed {
                zeroize()
            }
        }

        let candidatePeerKeyShares = try Self.validatedMessageAKeyShares(messageA)

        let identityKeys: IdentityPublicKeys
        do {
            identityKeys = try messageA.decodedIdentityPublicKeys()
            RemoteControlSmokeStatusWriter.append(
                "mac-handshake processA identity-decoded alg=\(identityKeys.protocolAlgorithm.rawValue)"
            )
        } catch {
            RemoteControlSmokeStatusWriter.append("mac-handshake processA identity-decode-failed error=\(error.localizedDescription)")
            throw HandshakeError.failed(.invalidMessageFormat("IdentityPublicKeys decode failed: \(error.localizedDescription)"))
        }

        let canonicalPreimage = messageA.signaturePreimage
        let canonicalDigest = SHA256.hash(data: canonicalPreimage).map { String(format: "%02x", $0) }.joined().prefix(16)
        let rawDigest = rawSignaturePreimage.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined().prefix(16) }

 // 验证签名
        RemoteControlSmokeStatusWriter.append("mac-handshake processA verify-canonical-start")
        var isValid = try await verifyHandshakeData(
            canonicalPreimage,
            signature: messageA.signature,
            publicKey: identityKeys.protocolPublicKey
        )
        try ensureActive(generation: generation)
        RemoteControlSmokeStatusWriter.append("mac-handshake processA verify-canonical-done ok=\(isValid)")
        SkyBridgeLogger.p2p.info(
            "🧪 processMessageA verify canonical alg=\(identityKeys.protocolAlgorithm.rawValue, privacy: .public) sigBytes=\(messageA.signature.count, privacy: .public) pubBytes=\(identityKeys.protocolPublicKey.count, privacy: .public) preimageSha256=\(canonicalDigest, privacy: .public) ok=\(isValid, privacy: .public)"
        )

        if !isValid,
           let rawSignaturePreimage,
           rawSignaturePreimage != canonicalPreimage {
            RemoteControlSmokeStatusWriter.append("mac-handshake processA verify-raw-start")
            let rawValid = try await verifyHandshakeData(
                rawSignaturePreimage,
                signature: messageA.signature,
                publicKey: identityKeys.protocolPublicKey
            )
            try ensureActive(generation: generation)
            RemoteControlSmokeStatusWriter.append("mac-handshake processA verify-raw-done ok=\(rawValid)")
            SkyBridgeLogger.p2p.info(
                "🧪 processMessageA verify raw alg=\(identityKeys.protocolAlgorithm.rawValue, privacy: .public) preimageSha256=\(rawDigest ?? "n/a", privacy: .public) ok=\(rawValid, privacy: .public)"
            )
            if rawValid {
                SkyBridgeLogger.p2p.warning(
                    "🧪 MessageA signature verified via raw-wire fallback alg=\(identityKeys.protocolAlgorithm.rawValue, privacy: .public)"
                )
                isValid = true
            }
        } else if let rawDigest {
            SkyBridgeLogger.p2p.info(
                "🧪 processMessageA raw preimage matches canonical alg=\(identityKeys.protocolAlgorithm.rawValue, privacy: .public) preimageSha256=\(rawDigest, privacy: .public)"
            )
        }

        guard isValid else {
            RemoteControlSmokeStatusWriter.append("mac-handshake processA verify-failed")
            throw HandshakeError.failed(.signatureVerificationFailed)
        }

        let candidateRemoteAuthority = try makeAuthenticatedRemoteAuthority(from: identityKeys)
        RemoteControlSmokeStatusWriter.append("mac-handshake processA authority-made")

        if let postSignatureValidation {
            RemoteControlSmokeStatusWriter.append("mac-handshake processA post-validation-start")
            try await postSignatureValidation(identityKeys)
            try ensureActive(generation: generation)
            RemoteControlSmokeStatusWriter.append("mac-handshake processA post-validation-done")
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
                try ensureActive(generation: generation)

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
        RemoteControlSmokeStatusWriter.append("mac-handshake processA se-check-done")

        RemoteControlSmokeStatusWriter.append("mac-handshake processA select-suite-start")
        let selectedSuite = try selectSuite(
            from: messageA,
            localPolicy: policy
        )
        RemoteControlSmokeStatusWriter.append("mac-handshake processA select-suite-done suite=\(selectedSuite.rawValue)")
        let candidateV2PeerContribution: Data?
        if selectedSuite.requiresV2EphemeralContribution {
            guard let contribution = messageA.initiatorContribution else {
                throw HandshakeError.failed(.invalidMessageFormat("Missing v2 initiator contribution"))
            }
            candidateV2PeerContribution = contribution
        } else {
            candidateV2PeerContribution = nil
        }

        var candidateKEMSharedSecret: SecureBytes?
        defer { candidateKEMSharedSecret?.zeroize() }
        if selectedSuite.isPQC {
            guard let provider = providerForSuite(selectedSuite),
                  let encapsulatedKey = candidatePeerKeyShares[selectedSuite] else {
                throw HandshakeError.invalidState("Missing KEM key share for \(selectedSuite.rawValue)")
            }

            RemoteControlSmokeStatusWriter.append("mac-handshake processA kem-identity-start suite=\(selectedSuite.rawValue)")
            let localKEM = try await kemIdentityStore.getOrCreateKEMIdentityKey(
                for: selectedSuite.canonicalKEMSuite,
                provider: provider
            )
            try ensureActive(generation: generation)
            RemoteControlSmokeStatusWriter.append("mac-handshake processA kem-identity-done suite=\(selectedSuite.rawValue)")
            RemoteControlSmokeStatusWriter.append("mac-handshake processA kem-decapsulate-start suite=\(selectedSuite.rawValue)")
            let sharedSecret: SecureBytes
            if selectedSuite == .qperiaptABI2PolicyBound {
                guard let policyBoundProvider = provider as? any ApplicationContextBoundCryptoProvider else {
                    throw HandshakeError.invalidState(
                        "Q-Periapt ABI2 provider does not expose its application-context contract"
                    )
                }
                let applicationContext = try QPeriaptHandshakeApplicationContext.messageA(
                    version: messageA.version,
                    suite: selectedSuite,
                    clientNonce: messageA.clientNonce,
                    recipientPublicKey: localKEM.publicKey,
                    policy: messageA.policy,
                    offeredSuites: messageA.supportedSuites,
                    capabilities: messageA.capabilities,
                    identityPublicKey: messageA.identityPublicKey,
                    extensionsRaw: messageA.extensionsRaw
                )
                sharedSecret = try await policyBoundProvider.kemDecapsulate(
                    encapsulatedKey: encapsulatedKey,
                    privateKey: localKEM.privateKey,
                    applicationContext: applicationContext
                )
            } else {
                sharedSecret = try await provider.kemDecapsulate(
                    encapsulatedKey: encapsulatedKey,
                    privateKey: localKEM.privateKey
                )
            }
            candidateKEMSharedSecret = sharedSecret
            try ensureActive(generation: generation)
            RemoteControlSmokeStatusWriter.append("mac-handshake processA kem-decapsulate-done suite=\(selectedSuite.rawValue)")
        }

        RemoteControlSmokeStatusWriter.append("mac-handshake processA replay-check-start suite=\(selectedSuite.rawValue)")
        try await ensureNotReplay(
            for: selectedSuite,
            replayTag: .messageA,
            remoteNonce: messageA.clientNonce
        )
        try ensureActive(generation: generation)
        RemoteControlSmokeStatusWriter.append("mac-handshake processA replay-check-done suite=\(selectedSuite.rawValue)")

        let transcriptA = SHA256.hash(data: messageA.transcriptBytes)

        // Commit only after every validation, native operation, and replay
        // registration has succeeded without lifecycle invalidation.
        peerKeyShares = candidatePeerKeyShares
        peerNonce = SecureBytes(data: messageA.clientNonce)
        peerCapabilities = messageA.capabilities
        negotiatedSuite = selectedSuite
        v2PeerInitiatorContribution = candidateV2PeerContribution
        if let sharedSecret = candidateKEMSharedSecret {
            kemSharedSecrets[selectedSuite] = sharedSecret
            candidateKEMSharedSecret = nil
        }
        transcriptHashA = SecureBytes(data: Data(transcriptA))
        authenticatedRemoteAuthority = candidateRemoteAuthority
        completed = true
        RemoteControlSmokeStatusWriter.append("mac-handshake processA keyshares-saved count=\(messageA.keyShares.count)")
        RemoteControlSmokeStatusWriter.append("mac-handshake processA transcriptA-done suite=\(selectedSuite.rawValue)")
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

        guard !isProcessingHandshakeMessage else {
            throw HandshakeError.invalidState("Another handshake operation is already in progress")
        }
        isProcessingHandshakeMessage = true
        let generation = lifecycleGeneration
        var completed = false
        defer {
            isProcessingHandshakeMessage = false
            if !completed {
                zeroize()
            }
        }

        guard let nonceData = nonce?.data,
              let suite = negotiatedSuite,
              let peerShare = peerKeyShares[suite],
              let provider = providerForSuite(suite) else {
            throw HandshakeError.invalidState("Missing required data for MessageB")
        }

        guard let transcriptHashA = transcriptHashA?.copyData() else {
            throw HandshakeError.invalidState("Missing transcript hash for MessageA")
        }

        let responderShare: Data
        let sealedBox: HPKESealedBox
        let sharedSecretForSession: SecureBytes
        if suite.isPQC {
            guard let sharedSecret = kemSharedSecrets[suite] else {
                throw HandshakeError.invalidState("Missing KEM shared secret for \(suite.rawValue)")
            }
            let payloadSecret: SecureBytes
            if suite.requiresV2EphemeralContribution {
                guard let initiatorContribution = v2PeerInitiatorContribution else {
                    throw HandshakeError.invalidState("Missing v2 initiator contribution")
                }
                let responderContribution = try deriveResponderV2Contribution(
                    initiatorContribution: initiatorContribution
                )
                responderShare = responderContribution.publicKey
                payloadSecret = try composeV2SharedSecret(
                    staticSecret: sharedSecret,
                    ephemeralSecret: responderContribution.sharedSecret,
                    suite: suite
                )
                responderContribution.sharedSecret.zeroize()
                sharedSecret.zeroize()
            } else {
                responderShare = Data()
                payloadSecret = sharedSecret
            }

            // 本端 capabilities 编码失败属内部不变量被破坏，必须显式失败，
            // 不得静默发送空载荷把内部错误伪装成"无能力"的合法握手。
            let responderCapabilities = Self.advertisedCapabilities(
                localCapabilities,
                for: [suite]
            )
            let payloadData = try responderCapabilities.deterministicEncode()
            sealedBox = try sealPayloadWithSharedSecret(
                payloadSecret,
                plaintext: payloadData,
                info: Data("handshake-payload".utf8),
                encapsulatedKey: Data()
            )
            sharedSecretForSession = payloadSecret
            kemSharedSecrets.removeValue(forKey: suite)
            v2PeerInitiatorContribution = nil
        } else {
            let responderCapabilities = Self.advertisedCapabilities(
                localCapabilities,
                for: [suite]
            )
            let payloadData = try responderCapabilities.deterministicEncode()
            let sealResult = try await provider.kemDemSealWithSecret(
                plaintext: payloadData,
                recipientPublicKey: peerShare,
                info: Data("handshake-payload".utf8)
            )
            do {
                try ensureActive(generation: generation)
            } catch {
                sealResult.sharedSecret.zeroize()
                throw error
            }
            sealedBox = sealResult.sealedBox
            sharedSecretForSession = sealResult.sharedSecret
            responderShare = sealedBox.encapsulatedKey
        }
        defer {
            if !completed {
                sharedSecretForSession.zeroize()
            }
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
        try ensureActive(generation: generation)
        let seSigPreimage = messageB.secureEnclaveSignaturePreimage(transcriptHashA: transcriptHashA)
        var seSignature: Data?
        if policy.requireSecureEnclavePoP, secureEnclaveKeyHandle == nil {
            throw HandshakeError.failed(.secureEnclavePoPRequired)
        }
        do {
            seSignature = try await signSecureEnclaveData(seSigPreimage, secureEnclaveKeyHandle: secureEnclaveKeyHandle)
            try ensureActive(generation: generation)
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
        try ensureActive(generation: generation)

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
        completed = true
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
        postSignatureValidation: (@Sendable (IdentityPublicKeys) async throws -> Void)? = nil,
        secureEnclavePublicKey: Data? = nil
    ) async throws -> SessionKeys {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        guard role == .initiator else {
            throw HandshakeError.invalidState("Only initiator can process MessageB")
        }

        guard !isProcessingHandshakeMessage else {
            throw HandshakeError.invalidState("A handshake message is already being processed")
        }
        isProcessingHandshakeMessage = true
        let generation = lifecycleGeneration
        var completed = false
        defer {
            isProcessingHandshakeMessage = false
            if !completed {
                zeroize()
            }
        }

 // 14.4: 检查 requirePQC 策略
 // Requirement 14.4: requirePQC 策略下 PQC 不可用时直接失败
        guard messageB.version == HandshakeConstants.protocolVersion else {
            throw HandshakeError.failed(.versionMismatch(
                local: HandshakeConstants.protocolVersion,
                remote: messageB.version
            ))
        }
        guard messageB.serverNonce.count == 32 else {
            throw HandshakeError.failed(.invalidMessageFormat("Invalid MessageB nonce length"))
        }
        if policy.requirePQC && !messageB.selectedSuite.isPQC {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }

        guard let transcriptHashA = transcriptHashA?.copyData() else {
            throw HandshakeError.invalidState("Missing transcript hash for MessageA")
        }
        guard let localNonce = nonce?.data else {
            throw HandshakeError.invalidState("Missing local nonce for MessageB")
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
        try ensureActive(generation: generation)

        guard isValid else {
            throw HandshakeError.failed(.signatureVerificationFailed)
        }

        let responderAuthority = try makeAuthenticatedRemoteAuthority(from: identityKeys)

        if let postSignatureValidation {
            try await postSignatureValidation(identityKeys)
            try ensureActive(generation: generation)
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
                try ensureActive(generation: generation)

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

        let candidateTranscriptB = Data(SHA256.hash(data: messageB.transcriptBytes))

 // 检查 suite 是否在 supportedSuites 且有 keyShare
        let selectedSuite = messageB.selectedSuite
        guard sentSupportedSuites.contains(selectedSuite),
              sentKeyShares[selectedSuite] != nil else {
            throw HandshakeError.failed(.suiteNegotiationFailed)
        }

        if selectedSuite.requiresV2EphemeralContribution {
            guard messageB.responderShare.count == 32 else {
                throw HandshakeError.failed(.invalidMessageFormat("v2 responder contribution missing"))
            }
        } else {
            guard messageB.responderShare == messageB.encryptedPayload.encapsulatedKey else {
                throw HandshakeError.failed(.invalidMessageFormat("Responder share mismatch"))
            }
        }

        try await ensureNotReplay(
            for: selectedSuite,
            replayTag: .messageB,
            remoteNonce: messageB.serverNonce
        )
        try ensureActive(generation: generation)

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

            let sessionSecret: SecureBytes
            if selectedSuite.requiresV2EphemeralContribution {
                let ephemeralSecret = try deriveInitiatorV2SharedSecret(
                    responderContribution: messageB.responderShare
                )
                sessionSecret = try composeV2SharedSecret(
                    staticSecret: payloadSecret,
                    ephemeralSecret: ephemeralSecret,
                    suite: selectedSuite
                )
                ephemeralSecret.zeroize()
                payloadSecret.zeroize()
            } else {
                sessionSecret = payloadSecret
            }

            defer { sessionSecret.zeroize() }
            let payload = try openPayloadWithSharedSecret(
                messageB.encryptedPayload,
                sharedSecret: sessionSecret,
                info: Data("handshake-payload".utf8)
            )
            let responderCapabilities = try Self.decodeResponderCapabilities(from: payload)
            try validateResponderCapabilities(
                responderCapabilities,
                selectedSuite: selectedSuite,
                policy: policy
            )
            let sessionKeys = try deriveSessionKeys(
                sharedSecret: sessionSecret,
                suite: selectedSuite,
                transcriptA: transcriptHashA,
                transcriptB: candidateTranscriptB,
                localNonce: localNonce,
                remoteNonce: messageB.serverNonce
            )
            kemSharedSecrets[selectedSuite]?.zeroize()
            kemSharedSecrets.removeValue(forKey: selectedSuite)
            commitProcessedMessageB(
                messageB,
                transcriptB: candidateTranscriptB,
                capabilities: responderCapabilities,
                authority: responderAuthority
            )
            completed = true
            return sessionKeys
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
        defer { openResult.sharedSecret.zeroize() }
        try ensureActive(generation: generation)

        let responderCapabilities = try Self.decodeResponderCapabilities(from: openResult.plaintext)
        try validateResponderCapabilities(
            responderCapabilities,
            selectedSuite: selectedSuite,
            policy: policy
        )

 // 派生会话密钥
        let sessionKeys = try deriveSessionKeys(
            sharedSecret: openResult.sharedSecret,
            suite: selectedSuite,
            transcriptA: transcriptHashA,
            transcriptB: candidateTranscriptB,
            localNonce: localNonce,
            remoteNonce: messageB.serverNonce
        )
        commitProcessedMessageB(
            messageB,
            transcriptB: candidateTranscriptB,
            capabilities: responderCapabilities,
            authority: responderAuthority
        )
        completed = true
        return sessionKeys
    }

    private func commitProcessedMessageB(
        _ messageB: HandshakeMessageB,
        transcriptB: Data,
        capabilities: CryptoCapabilities,
        authority: AuthenticatedRemoteAuthority
    ) {
        peerKeyShares[messageB.selectedSuite] = messageB.responderShare
        peerNonce = SecureBytes(data: messageB.serverNonce)
        negotiatedSuite = messageB.selectedSuite
        transcriptHashB = SecureBytes(data: transcriptB)
        peerCapabilities = capabilities
        authenticatedRemoteAuthority = authority
        v2InitiatorContributionPrivateKey?.zeroize()
        v2InitiatorContributionPrivateKey = nil
    }

 /// 响应方在发送 MessageB 后派生会话密钥
    public func finalizeResponderSessionKeys(sharedSecret: SecureBytes) throws -> SessionKeys {
        guard !isZeroized else {
            throw HandshakeError.contextZeroized
        }

        guard role == .responder else {
            throw HandshakeError.invalidState("Only responder can finalize session keys")
        }
        guard !isProcessingHandshakeMessage else {
            throw HandshakeError.invalidState("Another handshake operation is already in progress")
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
        let salt = transcriptHashA?.copyData() ?? Data()
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: info,
            outputByteCount: 32
        )

        var nonceBytes = [UInt8](repeating: 0, count: 12)
        guard Self.fillRandomBytes(&nonceBytes, label: 0x42) else {
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
        let salt = transcriptHashA?.copyData() ?? Data()
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

    private static func fillRandomBytes(_ bytes: inout [UInt8], label: UInt8) -> Bool {
        #if DEBUG || SKYBRIDGE_BENCHMARKING
        if ProcessInfo.processInfo.environment["SKYBRIDGE_BENCH_DETERMINISTIC_NONCE"] == "1" {
            deterministicNonceLock.lock()
            var state = deterministicNonceCounter &+ (UInt64(label) << 56)
            deterministicNonceCounter &+= 1
            deterministicNonceLock.unlock()

            var chunk: UInt64 = 0
            for index in bytes.indices {
                if index % 8 == 0 {
                    state &+= 0x9E3779B97F4A7C15
                    var mixed = state
                    mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
                    mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
                    chunk = mixed ^ (mixed >> 31)
                }
                let shift = UInt64((index % 8) * 8)
                bytes[index] = UInt8(truncatingIfNeeded: chunk >> shift)
            }
            return true
        }
        #endif

        return SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess
    }

 // MARK: - Key Derivation

 /// 派生会话密钥
    private func deriveSessionKeys(sharedSecret: SecureBytes) throws -> SessionKeys {
        guard let transcriptA = transcriptHashA?.copyData(),
              let transcriptB = transcriptHashB?.copyData(),
              let suite = negotiatedSuite,
              let localNonce = nonce?.data,
              let remoteNonce = peerNonce?.data else {
            throw HandshakeError.invalidState("Missing transcript, suite, nonces, or shared secret")
        }

        let sessionKeys = try deriveSessionKeys(
            sharedSecret: sharedSecret,
            suite: suite,
            transcriptA: transcriptA,
            transcriptB: transcriptB,
            localNonce: localNonce,
            remoteNonce: remoteNonce
        )
        kemSharedSecrets[suite]?.zeroize()
        kemSharedSecrets.removeValue(forKey: suite)
        sharedSecret.zeroize()
        return sessionKeys
    }

    /// Pure derivation surface used while an inbound MessageB is still staged.
    /// It must not mutate actor state or consume the caller-owned secret.
    private func deriveSessionKeys(
        sharedSecret: SecureBytes,
        suite: CryptoSuite,
        transcriptA: Data,
        transcriptB: Data,
        localNonce: Data,
        remoteNonce: Data
    ) throws -> SessionKeys {

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

        return sessionKeys
    }

 // MARK: - Zeroization

 /// 清理敏感数据
 ///
 /// **关键**：必须在握手完成或失败后调用
    public func zeroize() {
        lifecycleGeneration &+= 1

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
        v2InitiatorContributionPrivateKey?.zeroize()
        v2InitiatorContributionPrivateKey = nil
        v2PeerInitiatorContribution = nil

 // 清除公钥（非敏感但也清理）
        keyExchangePublicKeys.removeAll()
        peerKeyShares.removeAll()
        sentSupportedSuites.removeAll()
        sentKeyShares.removeAll()
        negotiatedSuite = nil
        peerCapabilities = nil
        authenticatedRemoteAuthority = nil

        isZeroized = true
    }
}

private enum ResponderCapabilityPayloadError: Error {
    case payloadTooLarge
    case collectionTooLarge
    case stringTooLarge
    case truncated
    case invalidUTF8
    case invalidBoolean
    case invalidProviderType
    case trailingBytes
    case nonCanonicalEncoding
}

/// Bounded decoder for the authenticated MessageB capability payload.
///
/// `DeterministicDecoder` is intentionally general-purpose and trusts encoded
/// collection counts. Network input needs tighter limits before allocating.
private struct ResponderCapabilityPayloadDecoder {
    private static let maximumPayloadLength = 4_096
    private static let maximumCollectionCount = 32
    private static let maximumStringLength = 512

    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func decode() throws -> CryptoCapabilities {
        guard data.count <= Self.maximumPayloadLength else {
            throw ResponderCapabilityPayloadError.payloadTooLarge
        }

        let supportedKEM = try decodeStringArray()
        let supportedSignature = try decodeStringArray()
        let supportedAuthProfiles = try decodeStringArray()
        let supportedAEAD = try decodeStringArray()
        let pqcAvailable = try decodeBool()
        let platformVersion = try decodeString()
        let providerTypeRaw = try decodeString()

        guard let providerType = CryptoProviderType(rawValue: providerTypeRaw) else {
            throw ResponderCapabilityPayloadError.invalidProviderType
        }
        guard offset == data.count else {
            throw ResponderCapabilityPayloadError.trailingBytes
        }

        return CryptoCapabilities(
            supportedKEM: supportedKEM,
            supportedSignature: supportedSignature,
            supportedAuthProfiles: supportedAuthProfiles,
            supportedAEAD: supportedAEAD,
            pqcAvailable: pqcAvailable,
            platformVersion: platformVersion,
            providerType: providerType
        )
    }

    private mutating func decodeStringArray() throws -> [String] {
        let count = Int(try decodeUInt32())
        guard count <= Self.maximumCollectionCount else {
            throw ResponderCapabilityPayloadError.collectionTooLarge
        }
        var values: [String] = []
        values.reserveCapacity(count)
        for _ in 0..<count {
            values.append(try decodeString())
        }
        return values
    }

    private mutating func decodeString() throws -> String {
        let length = Int(try decodeUInt32())
        guard length <= Self.maximumStringLength else {
            throw ResponderCapabilityPayloadError.stringTooLarge
        }
        guard offset <= data.count, length <= data.count - offset else {
            throw ResponderCapabilityPayloadError.truncated
        }
        let startIndex = data.index(data.startIndex, offsetBy: offset)
        let endIndex = data.index(startIndex, offsetBy: length)
        let bytes = data[startIndex..<endIndex]
        offset += length
        guard let value = String(data: bytes, encoding: .utf8) else {
            throw ResponderCapabilityPayloadError.invalidUTF8
        }
        return value
    }

    private mutating func decodeBool() throws -> Bool {
        guard offset < data.count else {
            throw ResponderCapabilityPayloadError.truncated
        }
        let index = data.index(data.startIndex, offsetBy: offset)
        let byte = data[index]
        offset += 1
        switch byte {
        case 0: return false
        case 1: return true
        default: throw ResponderCapabilityPayloadError.invalidBoolean
        }
    }

    private mutating func decodeUInt32() throws -> UInt32 {
        let width = MemoryLayout<UInt32>.size
        guard offset <= data.count, width <= data.count - offset else {
            throw ResponderCapabilityPayloadError.truncated
        }
        let startIndex = data.index(data.startIndex, offsetBy: offset)
        let value = UInt32(data[startIndex])
            | (UInt32(data[data.index(startIndex, offsetBy: 1)]) << 8)
            | (UInt32(data[data.index(startIndex, offsetBy: 2)]) << 16)
            | (UInt32(data[data.index(startIndex, offsetBy: 3)]) << 24)
        offset += width
        return value
    }
}

// MARK: - Replay Detection

@available(macOS 14.0, iOS 17.0, *)
extension HandshakeContext {
    private enum ReplayTag: UInt8 {
        case messageA = 0xA1
        case messageB = 0xB1
    }

    private func ensureNotReplay(
        for suite: CryptoSuite,
        replayTag: ReplayTag,
        remoteNonce: Data? = nil
    ) async throws {
        let handshakeId = try computeHandshakeId(
            for: suite,
            replayTag: replayTag,
            remoteNonce: remoteNonce
        )
        let isNew = await HandshakeReplayCache.shared.registerIfNew(handshakeId)
        guard isNew else {
            throw HandshakeError.failed(.replayDetected)
        }
    }

    private func computeHandshakeId(
        for suite: CryptoSuite,
        replayTag: ReplayTag,
        remoteNonce: Data?
    ) throws -> Data {
        guard let localNonce = nonce?.data,
              let effectiveRemoteNonce = remoteNonce ?? peerNonce?.data else {
            throw HandshakeError.invalidState("Missing nonces for handshakeId")
        }

        let initiatorNonce: Data
        let responderNonce: Data
        if role == .initiator {
            initiatorNonce = localNonce
            responderNonce = effectiveRemoteNonce
        } else {
            initiatorNonce = effectiveRemoteNonce
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
 // 可加性新增（Q-Periapt ContextBound, beta）：
 // 这是 Q-Periapt 套件在本握手层（`CryptoProvider` / `CryptoSuite` 抽象）的
 // 路由挂载点。`QPeriaptCryptoProvider`（本仓库新增）是一个完整的 `CryptoProvider`
 // 适配器：KEM = Q-Periapt 混合 (ML-KEM-768 + X25519)，DEM/签名与 `OQSPQCProvider`
 // 逐字节一致。仅当显式请求且本机 macOS/iOS 26+ CQPeriapt self-test 通过时挂载；否则与今天对该套件的
 // 行为完全一致（返回 nil → 后续 fall-through 也不会命中既有 provider，逐字节不变）。
 // 注意 `QPeriaptKEMProvider` 实现的是 `KEMProvider` 协议（见 CryptoProviderSelector.swift），
 // 与本函数返回的 `CryptoProvider` 协议面不同；二者各自服务于不同的接入层。
        if suite == .qperiaptABI2PolicyBound {
            #if canImport(CQPeriapt)
            if QPeriaptPlatformPolicy.isEnabledForLocalRuntime() {
                return QPeriaptPlatformPolicy.makeCryptoProvider()
            }
            #endif
            return nil
        }

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

    /// Q-Periapt ContextBound (beta) 是否启用。
    ///
    /// 默认 OFF。镜像 `CryptoProviderSelector.isQPeriaptBetaEnabled()` 的判定逻辑：
    /// - 环境变量 `SB_ENABLE_QPERIAPT` 为真值（1/true/yes/on）；或
    /// - UserDefaults 中 `SettingsStorageKeys.preferQPeriaptBeta` 为 true。
    ///
    /// 仅当本机 macOS/iOS 26+、CQPeriapt 模块可导入、且 runtime self-test 通过时才可能为真。
    nonisolated static func isQPeriaptBetaEnabled() -> Bool {
        QPeriaptPlatformPolicy.isEnabledForLocalRuntime()
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
        if canonical.wireId == CryptoSuite.mlkem768MLDSA65.wireId,
           let upgraded = peerKEMPublicKeys[.mlkem768MLDSA65FS] {
            return upgraded
        }
        return nil
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
        let sharedSecret = try responderPrivate.sharedSecretFromKeyAgreement(with: initiatorPublic)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        return (
            publicKey: responderPrivate.publicKey.rawRepresentation,
            sharedSecret: SecureBytes(data: sharedSecretData)
        )
    }

    private func deriveInitiatorV2SharedSecret(
        responderContribution: Data
    ) throws -> SecureBytes {
        guard responderContribution.count == 32 else {
            throw HandshakeError.failed(.invalidMessageFormat("Invalid v2 responder contribution length"))
        }
        guard let privateKeyData = v2InitiatorContributionPrivateKey?.copyData() else {
            throw HandshakeError.invalidState("Missing v2 initiator private contribution")
        }
        let initiatorPrivate = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKeyData)
        let responderPublic = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: responderContribution)
        let sharedSecret = try initiatorPrivate.sharedSecretFromKeyAgreement(with: responderPublic)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }
        return SecureBytes(data: sharedSecretData)
    }

    private func composeV2SharedSecret(
        staticSecret: SecureBytes,
        ephemeralSecret: SecureBytes,
        suite: CryptoSuite
    ) throws -> SecureBytes {
        var ikm = Data("SkyBridge-v2-compose|".utf8)
        ikm.append(staticSecret.copyData())
        ikm.append(ephemeralSecret.copyData())
        let inputKey = SymmetricKey(data: ikm)
        let salt = transcriptHashA?.copyData() ?? Data("SkyBridge-v2-salt".utf8)
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
            if role == .initiator, suite.isPQC, peerKEMPublicKey(for: suite) == nil {
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

        let primarySuite = cryptoProvider.supportedSuites.first ?? cryptoProvider.activeSuite
        if suites.isEmpty {
            guard suiteMeetsHandshakePolicy(primarySuite, policy: policy),
                  suiteMeetsLocalCryptoPolicy(primarySuite) else {
                throw HandshakeError.failed(.suiteNegotiationFailed)
            }
        }

        if role == .initiator, primarySuite.isPQC && peerKEMPublicKey(for: primarySuite) == nil {
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
                if suite == .qperiaptABI2PolicyBound,
                   !QPeriaptPlatformPolicy.isHandshakePeerEligible(messageA.capabilities) {
                    return false
                }
                if role == .initiator, peerKEMPublicKey(for: suite) == nil { return false }
                if !messageA.keyShares.contains(where: { $0.suite == suite }) { return false }
                if suite.requiresV2EphemeralContribution, messageA.initiatorContribution == nil { return false }
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
            } else if suite == .qperiaptABI2PolicyBound,
                      !QPeriaptPlatformPolicy.isHandshakePeerEligible(messageA.capabilities) {
                reason = "qperiapt_peer_capability_invalid"
            } else if role == .initiator, suite.isPQC && peerKEMPublicKey(for: suite) == nil {
                reason = "missing_peer_kem_key"
            } else if !messageA.keyShares.contains(where: { $0.suite == suite }) {
                reason = "missing_keyshare"
            } else if suite.requiresV2EphemeralContribution, messageA.initiatorContribution == nil {
                reason = "missing_v2_initiator_contribution"
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
