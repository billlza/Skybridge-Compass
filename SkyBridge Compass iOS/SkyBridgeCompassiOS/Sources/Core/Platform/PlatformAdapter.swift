//
// PlatformAdapter.swift
// SkyBridgeCompassiOS
//
// iOS 平台适配器
// 整合所有核心组件，提供统一的 API
//

import Foundation
import CryptoKit
import Network
#if canImport(OQSRAII)
import OQSRAII
#endif

// MARK: - SkyBridgeiOSCore

/// SkyBridge iOS 核心
/// 提供统一的 PQC 安全通信接口
@available(iOS 17.0, *)
@MainActor
public final class SkyBridgeiOSCore {
    typealias ProtocolIdentityResolver = @Sendable (
        ProtocolSigningAlgorithm,
        (any CryptoProvider)?
    ) async throws -> ResolvedProtocolSigningIdentity
    
    // MARK: - Singleton
    
    public static let shared = SkyBridgeiOSCore()
    
    // MARK: - Properties
    
    /// 加密 Provider
    public private(set) var cryptoProvider: (any CryptoProvider)?
    
    /// 签名 Provider
    public private(set) var signatureProvider: (any ProtocolSignatureProvider)?
    
    /// 身份密钥
    private var identityKeyHandle: SigningKeyHandle?
    private var identityPublicKey: Data?
    private var identitySnapshot: ProtocolIdentitySnapshot?
    
    /// 握手策略
    public var handshakePolicy: HandshakePolicy = .default
    
    /// 初始化状态
    public private(set) var isInitialized: Bool = false
    
    /// The last selection policy used to initialize the core.
    /// We must support re-initialization when the user toggles "enforce PQC" / compatibility settings.
    private var currentSelectionPolicy: CryptoProviderFactory.SelectionPolicy?
    private var activeInitializationToken: UUID?
    private let protocolIdentityResolver: ProtocolIdentityResolver
    nonisolated private static func randomAttemptIdBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }
    
    // MARK: - Initialization
    
    private init() {
        protocolIdentityResolver = { algorithm, provider in
            try await Self.resolveAuthoritativeProtocolSigningIdentity(
                for: algorithm,
                provider: provider
            )
        }
    }

    init(protocolIdentityResolver: @escaping ProtocolIdentityResolver) {
        self.protocolIdentityResolver = protocolIdentityResolver
    }
    
    /// 初始化核心组件
    /// - Parameter policy: 加密策略
    public func initialize(policy: CryptoProviderFactory.SelectionPolicy = .preferPQC) async throws {
        // Idempotency by policy: callers may invoke initialize multiple times (app launch + connect + settings toggles).
        // If policy changed, we MUST reconfigure handshakePolicy/provider/signing keys to match paper semantics.
        if activeInitializationToken == nil,
           isInitialized,
           currentSelectionPolicy == policy {
            return
        }
        let token = UUID()
        activeInitializationToken = token
        SkyBridgeLogger.shared.info("🧩 SkyBridgeiOSCore.initialize(policy=\(String(describing: policy)))")
        do {
            try await resolveAndCommitInitialization(
                token: token,
                policy: policy,
                handshakePolicy: Self.handshakePolicy(for: policy),
                provider: CryptoProviderFactory.make(policy: policy)
            )
        } catch {
            if activeInitializationToken == token {
                activeInitializationToken = nil
            }
            throw error
        }
    }

    public func initialize(
        policy: CryptoProviderFactory.SelectionPolicy,
        providerOverride: any CryptoProvider
    ) async throws {
        let token = UUID()
        activeInitializationToken = token
        SkyBridgeLogger.shared.info("🧩 SkyBridgeiOSCore.initialize(policy=\(String(describing: policy)), providerOverride=\(providerOverride.providerName))")
        do {
            try await resolveAndCommitInitialization(
                token: token,
                policy: policy,
                handshakePolicy: Self.handshakePolicy(for: policy),
                provider: providerOverride
            )
        } catch {
            if activeInitializationToken == token {
                activeInitializationToken = nil
            }
            throw error
        }
    }

    private static func handshakePolicy(
        for policy: CryptoProviderFactory.SelectionPolicy
    ) -> HandshakePolicy {
        switch policy {
        case .preferPQC:
            return .default
        case .requirePQC:
            return .strictPQC
        case .classicOnly:
            return HandshakePolicy(
                requirePQC: false,
                allowClassicFallback: false,
                minimumTier: .classic
            )
        }
    }

    private func resolveAndCommitInitialization(
        token: UUID,
        policy: CryptoProviderFactory.SelectionPolicy,
        handshakePolicy candidateHandshakePolicy: HandshakePolicy,
        provider candidateProvider: (any CryptoProvider)?
    ) async throws {
        let algorithm: ProtocolSigningAlgorithm = candidateProvider?.tier == .classic
            ? .ed25519
            : .mlDSA65
        let candidateSignatureProvider = ProtocolSignatureProviderSelector.select(
            for: algorithm
        )
        let identity = try await protocolIdentityResolver(algorithm, candidateProvider)
        try Task.checkCancellation()
        guard activeInitializationToken == token else {
            throw SkyBridgeError.handshakeFailed(
                reason: "Core initialization was superseded by a newer configuration request"
            )
        }
        guard identity.snapshot.signingAlgorithm == algorithm,
              identity.snapshot.signingPublicKey == identity.material.publicKey else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Protocol identity resolver returned a mismatched initialization snapshot"
            )
        }

        // Publish one complete configuration only after every fallible step has
        // succeeded. Failed policy changes preserve the prior coherent state.
        handshakePolicy = candidateHandshakePolicy
        cryptoProvider = candidateProvider
        signatureProvider = candidateSignatureProvider
        identityKeyHandle = .softwareKey(identity.material.privateKey)
        identityPublicKey = identity.material.publicKey
        identitySnapshot = identity.snapshot
        currentSelectionPolicy = policy
        isInitialized = true
        activeInitializationToken = nil
        SkyBridgeLogger.shared.info(
            "🧩 HandshakePolicy: requirePQC=\(candidateHandshakePolicy.requirePQC ? "1" : "0"), allowClassicFallback=\(candidateHandshakePolicy.allowClassicFallback ? "1" : "0"), minimumTier=\(candidateHandshakePolicy.minimumTier.rawValue)"
        )
    }

    public func getProtocolSigningKeyHandle(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> SigningKeyHandle {
        try await ensureInitializedForProtocolSigning(algorithm: algorithm)
        return try await getOrCreateProtocolSigningIdentity(for: algorithm).keyHandle
    }

    public func getProtocolSigningPublicKey(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> Data {
        try await ensureInitializedForProtocolSigning(algorithm: algorithm)
        return try await getOrCreateProtocolSigningIdentity(for: algorithm).publicKey
    }

    func getProtocolIdentitySnapshot(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> ProtocolIdentitySnapshot {
        try await ensureInitializedForProtocolSigning(algorithm: algorithm)
        return try await resolveProtocolSigningIdentity(for: algorithm).snapshot
    }

    func currentProtocolIdentitySnapshot() async throws -> ProtocolIdentitySnapshot {
        guard isInitialized,
              let algorithm = signatureProvider?.signatureAlgorithm else {
            throw SkyBridgeError.notInitialized
        }
        let resolved = try await resolveProtocolSigningIdentity(for: algorithm)
        identitySnapshot = resolved.snapshot
        return resolved.snapshot
    }

    func requireCurrentProtocolIdentitySnapshot() throws -> ProtocolIdentitySnapshot {
        guard isInitialized,
              let identitySnapshot,
              signatureProvider?.signatureAlgorithm == identitySnapshot.signingAlgorithm else {
            throw SkyBridgeError.notInitialized
        }
        return identitySnapshot
    }

    private func ensureInitializedForProtocolSigning(
        algorithm: ProtocolSigningAlgorithm
    ) async throws {
        guard algorithm == .mlDSA65 else {
            return
        }

        if isInitialized,
           let provider = cryptoProvider,
           provider.tier != .classic,
           signatureProvider?.signatureAlgorithm == .mlDSA65 {
            return
        }

        try await initialize(policy: .requirePQC)
        guard let provider = cryptoProvider,
              provider.tier != .classic,
              signatureProvider?.signatureAlgorithm == .mlDSA65 else {
            throw SkyBridgeError.handshakeFailed(
                reason: "ML-DSA identity key requested but requirePQC did not yield a PQC provider"
            )
        }
    }
    
    // MARK: - Identity Key Management
    
    private func getOrCreateProtocolSigningIdentity(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> (keyHandle: SigningKeyHandle, publicKey: Data) {
        if let currentSignatureProvider = signatureProvider,
           currentSignatureProvider.signatureAlgorithm == algorithm,
           let keyHandle = identityKeyHandle,
           let publicKey = identityPublicKey,
           await Self.isSigningKeyUsable(
                keyHandle: keyHandle,
                publicKey: publicKey,
                algorithm: algorithm
           ) {
            return (keyHandle, publicKey)
        }

        let resolved = try await resolveProtocolSigningIdentity(for: algorithm)
        return (.softwareKey(resolved.material.privateKey), resolved.material.publicKey)
    }
    
    // MARK: - Keychain Helpers
    
    nonisolated private static func decodeLegacyIdentityKeyData(
        _ keyData: Data,
        algorithm: ProtocolSigningAlgorithm
    ) throws -> ProtocolSigningIdentityMaterial {
        // 解析存储的数据（格式: privateKey || publicKey）
        switch algorithm {
        case .ed25519:
            guard keyData.count == 64 else {
                throw SkyBridgeError.invalidKeyData(reason: "Invalid Ed25519 identity key length")
            }
            let privateKeyData = keyData.prefix(32)
            let publicKeyData = keyData.suffix(32)
            return ProtocolSigningIdentityMaterial(
                algorithm: algorithm,
                privateKey: Data(privateKeyData),
                publicKey: Data(publicKeyData)
            )
            
        case .mlDSA65:
            let publicKeyLength = mldsaPublicKeyLength()
            guard publicKeyLength > 0, keyData.count > publicKeyLength else {
                throw SkyBridgeError.invalidKeyData(reason: "Invalid ML-DSA-65 identity key length")
            }
            let privateKeyData = keyData.prefix(keyData.count - publicKeyLength)
            let publicKeyData = keyData.suffix(publicKeyLength)
            return ProtocolSigningIdentityMaterial(
                algorithm: algorithm,
                privateKey: Data(privateKeyData),
                publicKey: Data(publicKeyData)
            )
        }
    }

    nonisolated private static func mldsaPublicKeyLength() -> Int {
        #if canImport(OQSRAII)
        let oqsLength = oqs_raii_mldsa65_public_key_length()
        if oqsLength > 0 {
            return oqsLength
        }
        #endif

        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return ApplePQCCryptoProvider.mldsa65PublicKeySize
        }
        #endif

        return 1952
    }

    nonisolated private static func isSigningKeyUsable(
        keyHandle: SigningKeyHandle,
        publicKey: Data,
        algorithm: ProtocolSigningAlgorithm
    ) async -> Bool {
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: algorithm)

        let probe = Data("skybridge.identity.selftest.v1".utf8)
        do {
            // Self-test may involve PQC signing/verification; run off main thread to avoid startup jank.
            return try await Task.detached(priority: .userInitiated) {
                let signature = try await signatureProvider.sign(probe, key: keyHandle)
                return try await signatureProvider.verify(probe, signature: signature, publicKey: publicKey)
            }.value
        } catch {
            return false
        }
    }

    private func resolveProtocolSigningIdentity(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> ResolvedProtocolSigningIdentity {
        try await protocolIdentityResolver(algorithm, cryptoProvider)
    }

    nonisolated private static func resolveAuthoritativeProtocolSigningIdentity(
        for algorithm: ProtocolSigningAlgorithm,
        provider: (any CryptoProvider)?
    ) async throws -> ResolvedProtocolSigningIdentity {
        try await ProtocolDeviceIdentityAuthority.shared.resolveSigningIdentity(
            for: algorithm,
            generate: {
                try await Self.generateIdentityKeyMaterial(
                    algorithm: algorithm,
                    provider: provider
                )
            },
            validate: { material in
                let usable = await Self.isSigningKeyUsable(
                    keyHandle: .softwareKey(material.privateKey),
                    publicKey: material.publicKey,
                    algorithm: algorithm
                )
                guard usable else {
                    throw SkyBridgeError.invalidKeyData(
                        reason: "Stored identity key failed self-test for \(algorithm.rawValue)"
                    )
                }
            },
            decodeLegacy: { data in
                try Self.decodeLegacyIdentityKeyData(data, algorithm: algorithm)
            }
        )
    }

    nonisolated private static func generateIdentityKeyMaterial(
        algorithm: ProtocolSigningAlgorithm,
        provider: (any CryptoProvider)?
    ) async throws -> ProtocolSigningIdentityMaterial {
        switch algorithm {
        case .ed25519:
            let privateKey = Curve25519.Signing.PrivateKey()
            return ProtocolSigningIdentityMaterial(
                algorithm: algorithm,
                privateKey: privateKey.rawRepresentation,
                publicKey: privateKey.publicKey.rawRepresentation
            )
        case .mlDSA65:
            guard let provider, provider.tier != .classic else {
                throw SkyBridgeError.handshakeFailed(
                    reason: "ML-DSA identity key requested without PQC provider"
                )
            }
            let keyPair = try await provider.generateKeyPair(for: .signing)
            return ProtocolSigningIdentityMaterial(
                algorithm: algorithm,
                privateKey: keyPair.privateKey.bytes,
                publicKey: keyPair.publicKey.bytes
            )
        }
    }

    private func supportsHandshakeSuite(
        _ suite: CryptoSuite,
        with provider: any CryptoProvider
    ) -> Bool {
        guard suite.isNegotiable else { return false }

        if suite == .xwing {
            guard provider.tier == .nativePQC,
                  provider.supportsSuite(suite) else {
                return false
            }
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                return AppleXWingCryptoProvider.quickRuntimeProbe()
            }
            #endif
            return false
        }

        // The iOS provider layer has no authenticated Q-Periapt ABI2 runtime.
        // A hybrid wire classification must never be treated as X-Wing support.
        if suite.isHybrid {
            return false
        }

        if suite.isPQCGroup {
            return provider.tier != .classic && provider.supportsSuite(suite)
        }

        return provider.supportsSuite(suite)
    }

    private func resolvedHandshakeSuites(
        for provider: any CryptoProvider,
        offeredSuites: [CryptoSuite]? = nil,
        peerSupportedSuites: [CryptoSuite]? = nil
    ) throws -> [CryptoSuite] {
        if let offeredSuites {
            guard !offeredSuites.isEmpty,
                  offeredSuites.allSatisfy(\.isNegotiable),
                  Set(offeredSuites.map(\.wireId)).count == offeredSuites.count,
                  offeredSuites.allSatisfy({ supportsHandshakeSuite($0, with: provider) }) else {
                throw HandshakeError.failed(.suiteNotSupported)
            }
            return offeredSuites
        }

        if let peerSupportedSuites {
            guard !peerSupportedSuites.isEmpty,
                  peerSupportedSuites.allSatisfy(\.isNegotiable),
                  Set(peerSupportedSuites.map(\.wireId)).count == peerSupportedSuites.count else {
                throw HandshakeError.failed(.suiteNotSupported)
            }
            let supported = peerSupportedSuites.filter { supportsHandshakeSuite($0, with: provider) }
            guard !supported.isEmpty else {
                throw HandshakeError.failed(.suiteNotSupported)
            }
            return supported
        }

        guard supportsHandshakeSuite(provider.activeSuite, with: provider) else {
            throw HandshakeError.failed(.suiteNotSupported)
        }
        return [provider.activeSuite]
    }
    
    // MARK: - Handshake API
    
    /// 创建握手驱动器
    public func createHandshakeDriver(
        transport: any DiscoveryTransport,
        offeredSuites: [CryptoSuite]? = nil,
        peerSupportedSuites: [CryptoSuite]? = nil,
        localSOAPeerId: Data? = nil,
        expectedRemoteSOAPeerId: Data? = nil,
        trustProvider: (any HandshakeTrustProvider)? = nil,
        authenticatedIncomingEstablishedPolicy: PeerSessionArbiter.IncomingEstablishedPolicy = .rejectDuplicate,
        soaSessionScope: PeerSessionArbiter.SessionScope = .p2p
    ) throws -> HandshakeDriver {
        guard isInitialized,
              let provider = cryptoProvider,
              let sigProvider = signatureProvider,
              let keyHandle = identityKeyHandle,
              let publicKey = identityPublicKey,
              let identitySnapshot,
              identitySnapshot.signingAlgorithm == sigProvider.signatureAlgorithm,
              identitySnapshot.signingPublicKey == publicKey else {
            throw SkyBridgeError.notInitialized
        }

        let handshakeSuites = try resolvedHandshakeSuites(
            for: provider,
            offeredSuites: offeredSuites,
            peerSupportedSuites: peerSupportedSuites
        )
        let cryptoPolicy = HandshakeCryptoPolicyResolver.policy(for: handshakeSuites)
        return HandshakeDriver(
            transport: transport,
            cryptoProvider: provider,
            protocolSignatureProvider: sigProvider,
            identityKeyHandle: keyHandle,
            sigAAlgorithm: sigProvider.signatureAlgorithm,
            identityPublicKey: publicKey,
            policy: handshakePolicy,
            cryptoPolicy: cryptoPolicy,
            offeredSuites: handshakeSuites,
            trustProvider: trustProvider,
            localSOAPeerId: localSOAPeerId,
            expectedRemoteSOAPeerId: expectedRemoteSOAPeerId,
            authenticatedIncomingEstablishedPolicy: authenticatedIncomingEstablishedPolicy,
            soaSessionScope: soaSessionScope
        )
    }
    
    /// 执行握手（带自动回退）
    public func performHandshake(
        deviceId: String,
        transport: any DiscoveryTransport,
        preferPQC: Bool = true,
        soaMetadata: HandshakeSOAMetadata? = nil,
        localSOAPeerId: Data? = nil,
        expectedRemoteSOAPeerId: Data? = nil,
        trustProvider: (any HandshakeTrustProvider)? = nil,
        soaSessionScope: PeerSessionArbiter.SessionScope = .p2p,
        onDriverCreated: (@Sendable (HandshakeDriver) async -> Void)? = nil
    ) async throws -> SessionKeys {
        guard isInitialized,
              let provider = cryptoProvider,
              let keyHandle = identityKeyHandle,
              let publicKey = identityPublicKey,
              let sigProvider = signatureProvider,
              let identitySnapshot,
              identitySnapshot.signingAlgorithm == sigProvider.signatureAlgorithm,
              identitySnapshot.signingPublicKey == publicKey else {
            throw SkyBridgeError.notInitialized
        }
        
        SkyBridgeLogger.shared.info(
            "🧩 performHandshake(policy): requirePQC=\(handshakePolicy.requirePQC ? "1" : "0"), " +
            "allowClassicFallback=\(handshakePolicy.allowClassicFallback ? "1" : "0"), " +
            "minimumTier=\(handshakePolicy.minimumTier.rawValue)"
        )
        let activeHandshakePolicy = handshakePolicy

        return try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
            deviceId: deviceId,
            preferPQC: preferPQC,
            policy: activeHandshakePolicy,
            cryptoProvider: provider
        ) { preparation in
            SkyBridgeLogger.shared.info(
                "🤝 Handshake attempt: strategy=\(preparation.strategy.rawValue), sigA=\(preparation.sigAAlgorithm.rawValue), " +
                "offeredSuites=\(preparation.offeredSuites.map { $0.rawValue }.joined(separator: ",")), " +
                "provider=\(preparation.cryptoProvider.providerName), activeSuite=\(preparation.cryptoProvider.activeSuite.rawValue), " +
                // Paper terminology alignment:
                "downgradeResistance=policy_gate+no_timeout_fallback+rate_limited, " +
                "policyInTranscript=1, transcriptBinding=1, " +
                "policyRequirePQC=\(activeHandshakePolicy.requirePQC ? "1" : "0"), " +
                "policyAllowClassicFallback=\(activeHandshakePolicy.allowClassicFallback ? "1" : "0"), " +
                "policyMinimumTier=\(activeHandshakePolicy.minimumTier.rawValue), " +
                "policyRequireSecureEnclavePoP=\(activeHandshakePolicy.requireSecureEnclavePoP ? "1" : "0")"
            )

            let attemptSOAMetadata: HandshakeSOAMetadata?
            if let localSOAPeerId, let expectedRemoteSOAPeerId {
                attemptSOAMetadata = try HandshakeSOAMetadata(
                    initiatorPeerId: localSOAPeerId,
                    targetPeerId: expectedRemoteSOAPeerId,
                    attemptId: Self.randomAttemptIdBytes()
                )
            } else {
                attemptSOAMetadata = soaMetadata
            }

            let driver = HandshakeDriver(
                transport: transport,
                cryptoProvider: preparation.cryptoProvider,
                protocolSignatureProvider: preparation.signatureProvider,
                identityKeyHandle: keyHandle,
                sigAAlgorithm: preparation.sigAAlgorithm,
                identityPublicKey: publicKey,
                policy: activeHandshakePolicy,
                cryptoPolicy: preparation.cryptoPolicy,
                offeredSuites: preparation.offeredSuites,
                trustProvider: trustProvider,
                soaMetadata: attemptSOAMetadata,
                localSOAPeerId: localSOAPeerId,
                expectedRemoteSOAPeerId: expectedRemoteSOAPeerId,
                soaSessionScope: soaSessionScope
            )

            if let onDriverCreated {
                await onDriverCreated(driver)
            }
            
            let peer = PeerIdentifier(deviceId: deviceId)
            return try await driver.initiateHandshake(with: peer)
        }
    }
    
    // MARK: - Crypto API
    
    /// 加密数据
    public func encrypt(_ plaintext: Data, sessionKey: Data) throws -> Data {
        let key = SymmetricKey(data: sessionKey)
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw SkyBridgeError.encryptionFailed(reason: "AES-GCM combined output unavailable")
        }
        return combined
    }
    
    /// 解密数据
    public func decrypt(_ ciphertext: Data, sessionKey: Data) throws -> Data {
        let key = SymmetricKey(data: sessionKey)
        let sealedBox = try AES.GCM.SealedBox(combined: ciphertext)
        return try AES.GCM.open(sealedBox, using: key)
    }
    
    // MARK: - Capability API
    
    /// 获取当前加密能力
    public func getCapabilities() -> CryptoCapabilities {
        guard let provider = cryptoProvider else {
            return CryptoCapabilities()
        }
        return CryptoCapabilities.fromProvider(provider)
    }
    
    /// 是否支持 PQC
    public var isPQCAvailable: Bool {
        let capability = CryptoProviderFactory.detectCapability()
        return capability.hasApplePQC || capability.hasLiboqs
    }
    
    /// 当前加密层级
    public var currentTier: CryptoTier {
        cryptoProvider?.tier ?? .classic
    }
}

// MARK: - SkyBridgeError

/// SkyBridge 错误
public enum SkyBridgeError: Error, LocalizedError {
    case notInitialized
    case keychainError(status: OSStatus)
    case invalidKeyData(reason: String)
    case handshakeFailed(reason: String)
    case encryptionFailed(reason: String)
    case decryptionFailed(reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "SkyBridge core not initialized"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .invalidKeyData(let reason):
            return "Invalid key data: \(reason)"
        case .handshakeFailed(let reason):
            return "Handshake failed: \(reason)"
        case .encryptionFailed(let reason):
            return "Encryption failed: \(reason)"
        case .decryptionFailed(let reason):
            return "Decryption failed: \(reason)"
        }
    }
}

// MARK: - P2P Transport Implementation

/// NWConnection 适配的传输层
@available(iOS 17.0, *)
public actor NWConnectionTransport: DiscoveryTransport {
    private var connections: [String: NWConnection] = [:]
    private let queue = DispatchQueue(label: "com.skybridge.transport")
    
    public init() {}
    
    public func setConnection(_ connection: NWConnection, for peerId: String) {
        connections[peerId] = connection
    }
    
    public func removeConnection(for peerId: String) {
        connections.removeValue(forKey: peerId)
    }
    
    public func send(to peer: PeerIdentifier, data: Data) async throws {
        guard let connection = connections[peer.deviceId] else {
            throw SkyBridgeError.handshakeFailed(reason: "No connection for peer: \(peer.deviceId)")
        }

        // 与 macOS 端一致：TCP 流上做 4-byte big-endian length framing
        var framed = Data()
        var length = UInt32(data.count).bigEndian
        framed.append(Data(bytes: &length, count: 4))
        framed.append(data)
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
