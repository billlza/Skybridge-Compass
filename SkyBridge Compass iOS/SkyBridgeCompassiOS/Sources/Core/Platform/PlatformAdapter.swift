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
import SkyBridgeProtocolCore
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
    typealias ExplicitProtocolIdentityResolver = @Sendable (
        ProtocolSigningAlgorithm,
        (any CryptoProvider)?,
        ProtocolSigningKeyProtection
    ) async throws -> ResolvedProtocolSigningIdentity

    struct PreparedProtocolSigningIdentity {
        let token: UUID
        let configuration: ProtocolIdentityConfigurationRecord
        let provider: any CryptoProvider
        let signatureProvider: any ProtocolSignatureProvider
        let keyHandle: SigningKeyHandle
        let publicKey: Data
        let snapshot: ProtocolIdentitySnapshot
    }
    
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

    /// Protection actually bound to the currently committed main-protocol
    /// signing identity. This describes only the local private-key residency;
    /// it is not remote hardware attestation.
    public private(set) var activeProtocolSigningKeyProtection: ProtocolSigningKeyProtection = .softwareKeychain
    
    /// The last selection policy used to initialize the core.
    /// We must support re-initialization when the user toggles "enforce PQC" / compatibility settings.
    private var currentSelectionPolicy: CryptoProviderFactory.SelectionPolicy?
    private var activeInitializationToken: UUID?
    private let protocolIdentityResolver: ProtocolIdentityResolver
    private let explicitProtocolIdentityResolver: ExplicitProtocolIdentityResolver
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
        explicitProtocolIdentityResolver = { algorithm, provider, protection in
            try await Self.resolveAuthoritativeProtocolSigningIdentity(
                for: algorithm,
                provider: provider,
                requiredProtection: protection
            )
        }
    }

    init(
        protocolIdentityResolver: @escaping ProtocolIdentityResolver,
        explicitProtocolIdentityResolver: ExplicitProtocolIdentityResolver? = nil
    ) {
        self.protocolIdentityResolver = protocolIdentityResolver
        self.explicitProtocolIdentityResolver = explicitProtocolIdentityResolver
            ?? { algorithm, provider, protection in
                try await Self.resolveAuthoritativeProtocolSigningIdentity(
                    for: algorithm,
                    provider: provider,
                    requiredProtection: protection
                )
            }
    }
    
    /// 初始化核心组件
    /// - Parameter policy: 加密策略
    public func initialize(policy: CryptoProviderFactory.SelectionPolicy = .preferPQC) async throws {
        let requestedConfiguration = try ProtocolSigningIdentityPolicy
            .requiredConfiguration()
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
                provider: CryptoProviderFactory.make(policy: policy),
                requestedConfiguration: requestedConfiguration
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
        let requestedConfiguration = try ProtocolSigningIdentityPolicy
            .requiredConfiguration()
        let token = UUID()
        activeInitializationToken = token
        SkyBridgeLogger.shared.info("🧩 SkyBridgeiOSCore.initialize(policy=\(String(describing: policy)), providerOverride=\(providerOverride.providerName))")
        do {
            try await resolveAndCommitInitialization(
                token: token,
                policy: policy,
                handshakePolicy: Self.handshakePolicy(for: policy),
                provider: providerOverride,
                requestedConfiguration: requestedConfiguration
            )
        } catch {
            if activeInitializationToken == token {
                activeInitializationToken = nil
            }
            throw error
        }
    }

    /// Provisions and atomically activates an explicit main-protocol identity
    /// configuration. The identity is fully restored and self-tested before
    /// any runtime field or persisted setting is changed.
#if DEBUG || SKYBRIDGE_TESTING
    func configureProtocolSigningIdentity(
        algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws {
        let prepared = try await prepareProtocolSigningIdentity(
            algorithm: algorithm,
            protection: protection
        )
        do {
            try commitPreparedProtocolSigningIdentity(prepared)
        } catch {
            abandonPreparedProtocolSigningIdentity(prepared)
            throw error
        }
    }
#endif

    /// Provisions and self-tests an exact candidate slot without publishing it
    /// as the current-path authority.
    func prepareProtocolSigningIdentity(
        algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> PreparedProtocolSigningIdentity {
        guard algorithm != .ed25519 else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Ed25519 is not a PQC identity configuration"
            )
        }
        let candidateProvider = CryptoProviderFactory.make(policy: .requirePQC)
        guard candidateProvider.tier != .classic else {
            throw SkyBridgeError.handshakeFailed(
                reason: "PQC provider unavailable for \(algorithm.rawValue)"
            )
        }
        let token = UUID()
        activeInitializationToken = token
        do {
            let identity = try await explicitProtocolIdentityResolver(
                algorithm,
                candidateProvider,
                protection
            )
            guard identity.snapshot.signingAlgorithm == algorithm,
                  identity.snapshot.signingPublicKey == identity.material.publicKey,
                  identity.material.algorithm == algorithm,
                  identity.material.keyProtection == protection else {
                throw SkyBridgeError.invalidKeyData(
                    reason: "Protocol identity resolver returned a mismatched explicit configuration"
                )
            }
            let keyHandle = try await IOSSecureEnclaveMLDSAIdentityFactory.keyHandle(
                for: identity.material
            )
            let candidateSignatureProvider = ProtocolSignatureProviderSelector.select(
                for: algorithm
            )
            guard await Self.isSigningKeyUsable(
                keyHandle: keyHandle,
                publicKey: identity.material.publicKey,
                algorithm: algorithm
            ) else {
                throw SkyBridgeError.invalidKeyData(
                    reason: "Provisioned \(algorithm.rawValue) identity failed final self-test"
                )
            }
            try Task.checkCancellation()
            guard activeInitializationToken == token else {
                throw SkyBridgeError.handshakeFailed(
                    reason: "Protocol identity configuration was superseded by a newer request"
                )
            }
            return PreparedProtocolSigningIdentity(
                token: token,
                configuration: ProtocolIdentityConfigurationRecord(
                    algorithm: algorithm,
                    keyProtection: protection
                ),
                provider: candidateProvider,
                signatureProvider: candidateSignatureProvider,
                keyHandle: keyHandle,
                publicKey: identity.material.publicKey,
                snapshot: identity.snapshot
            )
        } catch {
            if activeInitializationToken == token {
                activeInitializationToken = nil
            }
            throw error
        }
    }

    /// Commits a prepared local slot only after the remote rotation receipt has
    /// been validated. There is deliberately no suspension point here.
    func commitPreparedProtocolSigningIdentity(
        _ prepared: PreparedProtocolSigningIdentity
    ) throws {
        guard activeInitializationToken == prepared.token else {
            throw SkyBridgeError.handshakeFailed(
                reason: "Protocol identity configuration was superseded by a newer request"
            )
        }
        try ProtocolSigningIdentityPolicy.persist(prepared.configuration)
        handshakePolicy = .strictPQC
        cryptoProvider = prepared.provider
        signatureProvider = prepared.signatureProvider
        identityKeyHandle = prepared.keyHandle
        identityPublicKey = prepared.publicKey
        identitySnapshot = prepared.snapshot
        activeProtocolSigningKeyProtection = prepared.configuration.keyProtection
        currentSelectionPolicy = .requirePQC
        isInitialized = true
        activeInitializationToken = nil
    }

    func abandonPreparedProtocolSigningIdentity(
        _ prepared: PreparedProtocolSigningIdentity
    ) {
        if activeInitializationToken == prepared.token {
            activeInitializationToken = nil
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
        provider candidateProvider: (any CryptoProvider)?,
        requestedConfiguration: ProtocolIdentityConfigurationRecord
    ) async throws {
        let algorithm: ProtocolSigningAlgorithm = candidateProvider?.tier == .classic
            ? .ed25519
            : requestedConfiguration.algorithm
        let candidateSignatureProvider = ProtocolSignatureProviderSelector.select(
            for: algorithm
        )
        let identity = try await protocolIdentityResolver(algorithm, candidateProvider)
        guard identity.snapshot.signingAlgorithm == algorithm,
              identity.snapshot.signingPublicKey == identity.material.publicKey,
              identity.material.keyProtection == (
                algorithm == .ed25519
                    ? ProtocolSigningKeyProtection.softwareKeychain
                    : requestedConfiguration.keyProtection
              ) else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Protocol identity resolver returned a mismatched initialization snapshot"
            )
        }
        let candidateKeyHandle = try await IOSSecureEnclaveMLDSAIdentityFactory.keyHandle(
            for: identity.material
        )
        try Task.checkCancellation()
        guard activeInitializationToken == token else {
            throw SkyBridgeError.handshakeFailed(
                reason: "Core initialization was superseded by a newer configuration request"
            )
        }
        guard try ProtocolSigningIdentityPolicy.requiredConfiguration()
            == requestedConfiguration else {
            throw SkyBridgeError.handshakeFailed(
                reason: "Core initialization configuration changed while identity resolution was in progress"
            )
        }

        // Publish one complete configuration only after every fallible step has
        // succeeded. Failed policy changes preserve the prior coherent state.
        handshakePolicy = candidateHandshakePolicy
        cryptoProvider = candidateProvider
        signatureProvider = candidateSignatureProvider
        identityKeyHandle = candidateKeyHandle
        identityPublicKey = identity.material.publicKey
        identitySnapshot = identity.snapshot
        activeProtocolSigningKeyProtection = identity.material.keyProtection
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

    /// Resolves one exact `(algorithm, protection)` slot and returns its public
    /// authority and signing handle as one value. Callers must not pair a public
    /// snapshot with a later settings-derived key-handle lookup.
    func committedProtocolIdentitySnapshot(
        for algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> CommittedIOSProtocolIdentitySnapshot {
        guard algorithm != .ed25519 || protection == .softwareKeychain else {
            throw ProtocolDeviceIdentityError.unsupportedKeyProtection(
                algorithm,
                protection
            )
        }

        let provider: (any CryptoProvider)?
        if algorithm == .ed25519 {
            provider = cryptoProvider
        } else if let cryptoProvider, cryptoProvider.tier != .classic {
            provider = cryptoProvider
        } else {
            let candidate = CryptoProviderFactory.make(policy: .requirePQC)
            guard candidate.tier != .classic else {
                throw HandshakeError.failed(.pqcProviderUnavailable)
            }
            provider = candidate
        }

        let resolved = try await explicitProtocolIdentityResolver(
            algorithm,
            provider,
            protection
        )
        guard resolved.snapshot.signingAlgorithm == algorithm,
              resolved.snapshot.signingPublicKey == resolved.material.publicKey,
              resolved.material.algorithm == algorithm,
              resolved.material.keyProtection == protection else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Protocol identity resolver returned a mismatched committed snapshot"
            )
        }
        let keyHandle = try await IOSSecureEnclaveMLDSAIdentityFactory.keyHandle(
            for: resolved.material
        )
        guard await Self.isSigningKeyUsable(
            keyHandle: keyHandle,
            publicKey: resolved.material.publicKey,
            algorithm: algorithm
        ) else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Committed \(algorithm.rawValue)/\(protection.rawValue) identity failed self-test"
            )
        }
        return CommittedIOSProtocolIdentitySnapshot(
            snapshot: resolved.snapshot,
            algorithm: algorithm,
            protection: protection,
            publicKey: resolved.material.publicKey,
            keyHandle: keyHandle
        )
    }

    func committedActiveProtocolIdentitySnapshot() async throws
        -> CommittedIOSProtocolIdentitySnapshot {
        let configuration = try ProtocolSigningIdentityPolicy.requiredConfiguration()
        let snapshot = try await committedProtocolIdentitySnapshot(
            for: configuration.algorithm,
            protection: configuration.keyProtection
        )
        guard try ProtocolSigningIdentityPolicy.requiredConfiguration() == configuration else {
            throw SkyBridgeError.handshakeFailed(
                reason: "Protocol identity configuration changed while the active snapshot was resolving"
            )
        }
        return snapshot
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
        guard algorithm != .ed25519 else {
            return
        }

        if isInitialized,
           let provider = cryptoProvider,
           provider.tier != .classic {
            return
        }

        try await initialize(policy: .requirePQC)
        guard let provider = cryptoProvider,
              provider.tier != .classic else {
            throw SkyBridgeError.handshakeFailed(
                reason: "\(algorithm.rawValue) identity key requested but requirePQC did not yield a PQC provider"
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
        let keyHandle = try await IOSSecureEnclaveMLDSAIdentityFactory.keyHandle(
            for: resolved.material
        )
        return (keyHandle, resolved.material.publicKey)
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
        case .mlDSA87:
            throw SkyBridgeError.invalidKeyData(
                reason: "ML-DSA-87 has no legacy concatenated identity format"
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
        provider: (any CryptoProvider)?,
        requiredProtection: ProtocolSigningKeyProtection? = nil
    ) async throws -> ResolvedProtocolSigningIdentity {
        let requestedProtection: ProtocolSigningKeyProtection
        if algorithm == .ed25519 {
            requestedProtection = .softwareKeychain
        } else if let requiredProtection {
            requestedProtection = requiredProtection
        } else {
            let configuration = try ProtocolSigningIdentityPolicy.requiredConfiguration()
            guard configuration.algorithm == algorithm else {
                throw ProtocolDeviceIdentityError.corruptIdentityConfiguration
            }
            requestedProtection = configuration.keyProtection
        }
        return try await ProtocolDeviceIdentityAuthority.shared.resolveSigningIdentity(
            for: algorithm,
            keyProtection: requestedProtection,
            generate: {
                try await Self.generateIdentityKeyMaterial(
                    algorithm: algorithm,
                    provider: provider,
                    protection: requestedProtection
                )
            },
            validate: { material in
                guard material.keyProtection == requestedProtection else {
                    throw ProtocolDeviceIdentityError.signingAuthorityConflict(
                        algorithm
                    )
                }
                let keyHandle = try await IOSSecureEnclaveMLDSAIdentityFactory
                    .keyHandle(for: material)
                let usable = await Self.isSigningKeyUsable(
                    keyHandle: keyHandle,
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
        provider: (any CryptoProvider)?,
        protection requestedProtection: ProtocolSigningKeyProtection
    ) async throws -> ProtocolSigningIdentityMaterial {
        if algorithm != .ed25519,
           requestedProtection == .secureEnclaveRequired {
            return try await IOSSecureEnclaveMLDSAIdentityFactory.create(
                algorithm: algorithm
            )
        }
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
        case .mlDSA87:
            #if HAS_APPLE_PQC_SDK
            guard #available(iOS 26.0, macOS 26.0, *) else {
                throw SkyBridgeError.handshakeFailed(
                    reason: "ML-DSA-87 software identity requires iOS 26 or newer"
                )
            }
            let privateKey = try MLDSA87.PrivateKey()
            return ProtocolSigningIdentityMaterial(
                algorithm: algorithm,
                privateKey: privateKey.integrityCheckedRepresentation,
                publicKey: privateKey.publicKey.rawRepresentation
            )
            #else
            throw SkyBridgeError.handshakeFailed(
                reason: "ML-DSA-87 software identity requires the Apple PQC SDK"
            )
            #endif
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

        if suite == .qperiaptABI2PolicyBound {
            guard let requiredConfiguration = try? ProtocolSigningIdentityPolicy
                    .requiredConfiguration(),
                  requiredConfiguration.algorithm == .mlDSA65,
                  signatureProvider?.signatureAlgorithm == .mlDSA65,
                  identitySnapshot?.signingAlgorithm == .mlDSA65,
                  activeProtocolSigningKeyProtection == requiredConfiguration.keyProtection,
                  QPeriaptIOSRuntime.isEnabledForLocalRuntime(),
                  let session = QPeriaptIOSRuntime.currentSession,
                  let provider = provider as? any QPeriaptRuntimeBoundCryptoProvider else {
                return false
            }
            return provider.qPeriaptTrustRootFingerprint == session.trustRootFingerprint
                && provider.qPeriaptAuthProfile == session.authProfile
                && provider.supportsSuite(suite)
        }

        // A generic hybrid wire classification must never be treated as X-Wing
        // or Q-Periapt support without its suite-specific runtime admission.
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

    /// Selects an explicitly separate software compatibility identity for
    /// non-current-path peer handshakes. Authority-bound WebRTC sessions must
    /// use `authorityBoundCurrentPathPQCSignatureAlgorithm` instead.
    nonisolated static func peerPQCSignatureAlgorithm(
        requestedPQCAlgorithm: ProtocolSigningAlgorithm,
        hasAuthenticatedMLDSA87Binding: Bool
    ) -> ProtocolSigningAlgorithm {
        requestedPQCAlgorithm == .mlDSA87 && hasAuthenticatedMLDSA87Binding
            ? .mlDSA87
            : .mlDSA65
    }

    /// Selects the signer for an authority-bound current-path session.
    /// Unlike the separate peer-compatibility path, an admitted ML-DSA-87
    /// authority must never be represented by an ML-DSA-65 handshake key.
    nonisolated static func authorityBoundCurrentPathPQCSignatureAlgorithm(
        requestedPQCAlgorithm: ProtocolSigningAlgorithm,
        hasAuthenticatedMLDSA87Binding: Bool
    ) throws -> ProtocolSigningAlgorithm {
        guard requestedPQCAlgorithm == .mlDSA87 else {
            return requestedPQCAlgorithm
        }
        guard hasAuthenticatedMLDSA87Binding else {
            throw HandshakeError.failed(
                .identityMismatch(
                    expected: "authenticated current-path ML-DSA-87 key binding",
                    actual: "missing ML-DSA-87 authority for an admitted ML-DSA-87 session"
                )
            )
        }
        return .mlDSA87
    }

    nonisolated static func protocolSigningKeyProtection(
        for algorithm: ProtocolSigningAlgorithm,
        requestedPQCAlgorithm: ProtocolSigningAlgorithm,
        requestedPQCProtection: ProtocolSigningKeyProtection
    ) -> ProtocolSigningKeyProtection {
        guard algorithm != .ed25519,
              algorithm == requestedPQCAlgorithm else {
            return .softwareKeychain
        }
        return requestedPQCProtection
    }

    nonisolated static func validatedIncomingProtocolSigningAlgorithm(
        messageAlgorithm: ProtocolSigningAlgorithm,
        messagePublicKey: Data,
        requestedPQCAlgorithm: ProtocolSigningAlgorithm,
        durableAuthenticatedMLDSA87PublicKey: Data?,
        sessionAuthenticatedMLDSA87PublicKey: Data?
    ) throws -> ProtocolSigningAlgorithm {
        if requestedPQCAlgorithm == .mlDSA87,
           messageAlgorithm != .mlDSA87 {
            throw HandshakeError.failed(
                .identityMismatch(
                    expected: "ML-DSA-87 for the admitted current-path authority",
                    actual: "received \(messageAlgorithm.rawValue)"
                )
            )
        }
        guard messageAlgorithm == .mlDSA87 else {
            return messageAlgorithm
        }
        let authenticatedMLDSA87PublicKey = try resolvedAuthenticatedMLDSA87PublicKey(
            durablePublicKey: durableAuthenticatedMLDSA87PublicKey,
            sessionPublicKey: sessionAuthenticatedMLDSA87PublicKey
        )
        guard requestedPQCAlgorithm == .mlDSA87,
              authenticatedMLDSA87PublicKey == messagePublicKey else {
            throw HandshakeError.failed(
                .identityMismatch(
                    expected: "authenticated current-path ML-DSA-87 key binding",
                    actual: "unapproved or non-matching ML-DSA-87 identity"
                )
            )
        }
        return .mlDSA87
    }

    /// Resolves the raw ML-DSA-87 authority available to one handshake. A
    /// signed QR authority is session-scoped; it can authorize this handshake
    /// but does not become durable trust until the authenticated handshake is
    /// committed. Conflicting durable and session authorities always fail
    /// closed instead of silently preferring either source.
    nonisolated static func resolvedAuthenticatedMLDSA87PublicKey(
        durablePublicKey: Data?,
        sessionPublicKey: Data?
    ) throws -> Data? {
        if let durablePublicKey,
           let sessionPublicKey,
           durablePublicKey != sessionPublicKey {
            throw HandshakeError.failed(
                .identityMismatch(
                    expected: "consistent durable and current-path ML-DSA-87 authority",
                    actual: "conflicting ML-DSA-87 authority bindings"
                )
            )
        }
        return durablePublicKey ?? sessionPublicKey
    }

    public func preferredPQCSignatureAlgorithm(
        for deviceId: String
    ) throws -> ProtocolSigningAlgorithm {
        let requested = try ProtocolSigningIdentityPolicy.requiredConfiguration().algorithm
        let hasAuthenticatedMLDSA87Binding = requested == .mlDSA87
            && TrustedDeviceStore.shared.currentPathProtocolIdentityKeyBinding(
                for: deviceId,
                algorithm: .mlDSA87
            ) != nil
        return Self.peerPQCSignatureAlgorithm(
            requestedPQCAlgorithm: requested,
            hasAuthenticatedMLDSA87Binding: hasAuthenticatedMLDSA87Binding
        )
    }

    /// Selects the initiator signature algorithm for the active path. The
    /// session authority is deliberately ephemeral and is never written by
    /// this selector; durable trust is updated only after handshake success.
    public func currentPathPQCSignatureAlgorithm(
        for deviceId: String,
        sessionAuthenticatedMLDSA87PublicKey: Data?,
        requestedPQCAlgorithm: ProtocolSigningAlgorithm
    ) throws -> ProtocolSigningAlgorithm {
        let authenticatedPublicKey = try resolvedCurrentPathMLDSA87PublicKey(
            for: deviceId,
            sessionAuthenticatedMLDSA87PublicKey: sessionAuthenticatedMLDSA87PublicKey
        )
        return try Self.authorityBoundCurrentPathPQCSignatureAlgorithm(
            requestedPQCAlgorithm: requestedPQCAlgorithm,
            hasAuthenticatedMLDSA87Binding: authenticatedPublicKey != nil
        )
    }

    public func resolvedCurrentPathMLDSA87PublicKey(
        for deviceId: String,
        sessionAuthenticatedMLDSA87PublicKey: Data?
    ) throws -> Data? {
        let durablePublicKey = TrustedDeviceStore.shared
            .currentPathProtocolIdentityKeyBinding(
                for: deviceId,
                algorithm: .mlDSA87
            )?
            .publicKeyBytes
        let authenticatedPublicKey = try Self.resolvedAuthenticatedMLDSA87PublicKey(
            durablePublicKey: durablePublicKey,
            sessionPublicKey: sessionAuthenticatedMLDSA87PublicKey
        )
        return authenticatedPublicKey
    }

    public func preferredProtocolSigningKeyProtection(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> ProtocolSigningKeyProtection {
        let configuration = try ProtocolSigningIdentityPolicy.requiredConfiguration()
        return Self.protocolSigningKeyProtection(
            for: algorithm,
            requestedPQCAlgorithm: configuration.algorithm,
            requestedPQCProtection: configuration.keyProtection
        )
    }

    /// Selects the responder signature algorithm from the authenticated
    /// initiator identity. ML-DSA-87 is admitted only when the exact raw key in
    /// MessageA is already bound to the active current-path trust record.
    public func validatedIncomingProtocolSigningAlgorithm(
        messageA: HandshakeMessageA,
        stableDeviceId: String,
        sessionAuthenticatedMLDSA87PublicKey: Data? = nil,
        requestedPQCAlgorithm: ProtocolSigningAlgorithm? = nil
    ) throws -> ProtocolSigningAlgorithm {
        let identity = try messageA.decodedIdentityPublicKeys().asProtocolIdentityKeys()
        let binding = TrustedDeviceStore.shared.currentPathProtocolIdentityKeyBinding(
            for: stableDeviceId,
            algorithm: .mlDSA87
        )
        return try Self.validatedIncomingProtocolSigningAlgorithm(
            messageAlgorithm: identity.protocolAlgorithm,
            messagePublicKey: identity.protocolPublicKey,
            requestedPQCAlgorithm: requestedPQCAlgorithm
                ?? (try ProtocolSigningIdentityPolicy.requiredConfiguration().algorithm),
            durableAuthenticatedMLDSA87PublicKey: binding?.publicKeyBytes,
            sessionAuthenticatedMLDSA87PublicKey: sessionAuthenticatedMLDSA87PublicKey
        )
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
        let requiredConfiguration = try ProtocolSigningIdentityPolicy.requiredConfiguration()
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
        if provider.tier != .classic {
            guard identitySnapshot.signingAlgorithm == requiredConfiguration.algorithm,
                  activeProtocolSigningKeyProtection == requiredConfiguration.keyProtection else {
                throw SkyBridgeError.handshakeFailed(
                    reason: "Committed protocol identity no longer matches required configuration"
                )
            }
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
            protocolSigningKeyProtection: activeProtocolSigningKeyProtection,
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

    /// Creates a driver with an explicit protocol-signing identity slot. This
    /// is used by peer-scoped paths so a globally selected ML-DSA-87 identity
    /// is never sent to an unpinned peer, and a Secure Enclave requirement is
    /// never silently satisfied by a software key.
    public func createHandshakeDriver(
        transport: any DiscoveryTransport,
        offeredSuites: [CryptoSuite]? = nil,
        peerSupportedSuites: [CryptoSuite]? = nil,
        localSOAPeerId: Data? = nil,
        expectedRemoteSOAPeerId: Data? = nil,
        trustProvider: (any HandshakeTrustProvider)? = nil,
        authenticatedIncomingEstablishedPolicy: PeerSessionArbiter.IncomingEstablishedPolicy = .rejectDuplicate,
        soaSessionScope: PeerSessionArbiter.SessionScope = .p2p,
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolSigningKeyProtection: ProtocolSigningKeyProtection? = nil
    ) async throws -> HandshakeDriver {
        let requiredConfiguration = try ProtocolSigningIdentityPolicy.requiredConfiguration()
        guard isInitialized,
              let provider = cryptoProvider else {
            throw SkyBridgeError.notInitialized
        }
        guard protocolSigningAlgorithm == .ed25519 || provider.tier != .classic else {
            throw HandshakeError.failed(.pqcProviderUnavailable)
        }
        if provider.tier == .qperiaptPQC,
           (protocolSigningAlgorithm != .mlDSA65
                || requiredConfiguration.algorithm != .mlDSA65) {
            throw HandshakeError.failed(.identityMismatch(
                expected: "committed ML-DSA-65 for Q-Periapt ABI2 policy authentication",
                actual: protocolSigningAlgorithm.rawValue
            ))
        }

        let requiredProtection: ProtocolSigningKeyProtection
        if let protocolSigningKeyProtection {
            requiredProtection = protocolSigningKeyProtection
        } else {
            requiredProtection = try preferredProtocolSigningKeyProtection(
                for: protocolSigningAlgorithm
            )
        }
        if provider.tier == .qperiaptPQC,
           requiredProtection != requiredConfiguration.keyProtection {
            throw HandshakeError.failed(.identityMismatch(
                expected: requiredConfiguration.keyProtection.rawValue,
                actual: requiredProtection.rawValue
            ))
        }
        let identity = try await Self.resolveAuthoritativeProtocolSigningIdentity(
            for: protocolSigningAlgorithm,
            provider: provider,
            requiredProtection: requiredProtection
        )
        let keyHandle = try await IOSSecureEnclaveMLDSAIdentityFactory.keyHandle(
            for: identity.material
        )
        let signatureProvider = ProtocolSignatureProviderSelector.select(
            for: protocolSigningAlgorithm
        )
        let handshakeSuites = try resolvedHandshakeSuites(
            for: provider,
            offeredSuites: offeredSuites,
            peerSupportedSuites: peerSupportedSuites
        )
        let cryptoPolicy = HandshakeCryptoPolicyResolver.policy(for: handshakeSuites)
        return HandshakeDriver(
            transport: transport,
            cryptoProvider: provider,
            protocolSignatureProvider: signatureProvider,
            identityKeyHandle: keyHandle,
            sigAAlgorithm: protocolSigningAlgorithm,
            protocolSigningKeyProtection: requiredProtection,
            identityPublicKey: identity.material.publicKey,
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
              let provider = cryptoProvider else {
            throw SkyBridgeError.notInitialized
        }

        let requiredConfiguration = try ProtocolSigningIdentityPolicy.requiredConfiguration()
        let requestedPQCAlgorithm = requiredConfiguration.algorithm
        let peerPQCSignatureAlgorithm = try preferredPQCSignatureAlgorithm(for: deviceId)
        let peerPQCKeyProtection = Self.protocolSigningKeyProtection(
            for: peerPQCSignatureAlgorithm,
            requestedPQCAlgorithm: requestedPQCAlgorithm,
            requestedPQCProtection: requiredConfiguration.keyProtection
        )
        
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
            cryptoProvider: provider,
            pqcSignatureAlgorithm: peerPQCSignatureAlgorithm
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

            let protection: ProtocolSigningKeyProtection = preparation.sigAAlgorithm == .ed25519
                ? .softwareKeychain
                : peerPQCKeyProtection
            let identity = try await Self.resolveAuthoritativeProtocolSigningIdentity(
                for: preparation.sigAAlgorithm,
                provider: preparation.cryptoProvider,
                requiredProtection: protection
            )
            let keyHandle = try await IOSSecureEnclaveMLDSAIdentityFactory.keyHandle(
                for: identity.material
            )

            let driver = HandshakeDriver(
                transport: transport,
                cryptoProvider: preparation.cryptoProvider,
                protocolSignatureProvider: preparation.signatureProvider,
                identityKeyHandle: keyHandle,
                sigAAlgorithm: preparation.sigAAlgorithm,
                protocolSigningKeyProtection: protection,
                identityPublicKey: identity.material.publicKey,
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

@available(iOS 17.0, *)
public enum NWConnectionTransportBindingError: Error, LocalizedError, Sendable, Equatable {
    case connectionUnavailable
    case boundCapabilityRequired
    case staleBinding
    case peerMismatch

    public var errorDescription: String? {
        switch self {
        case .connectionUnavailable:
            return "No connection is installed for the peer"
        case .boundCapabilityRequired:
            return "A lease-bound transport capability is required"
        case .staleBinding:
            return "The transport binding was replaced"
        case .peerMismatch:
            return "The transport capability does not belong to this peer"
        }
    }
}

/// NWConnection 适配的传输层
@available(iOS 17.0, *)
public actor NWConnectionTransport: DiscoveryTransport {
    /// A capability tied to one exact peer, socket, and monotonic manager
    /// sequence. Handshake drivers retain this value instead of retaining the
    /// peer-keyed transport registry, so an old driver cannot borrow a
    /// replacement socket after actor reentrancy.
    public struct BoundTransport: DiscoveryTransport {
        private let owner: NWConnectionTransport
        private let peerId: String
        private let connection: NWConnection
        private let leaseSequence: UInt64

        fileprivate init(
            owner: NWConnectionTransport,
            peerId: String,
            connection: NWConnection,
            leaseSequence: UInt64
        ) {
            self.owner = owner
            self.peerId = peerId
            self.connection = connection
            self.leaseSequence = leaseSequence
        }

        public func send(to peer: PeerIdentifier, data: Data) async throws {
            guard peer.deviceId == peerId else {
                throw NWConnectionTransportBindingError.peerMismatch
            }
            try await owner.send(
                data,
                to: peerId,
                expectedConnection: connection,
                leaseSequence: leaseSequence
            )
        }
    }

    private struct ConnectionBinding {
        let connection: NWConnection
        let leaseSequence: UInt64?
    }

    private var connections: [String: ConnectionBinding] = [:]
    private let queue = DispatchQueue(label: "com.skybridge.transport")
    
    public init() {}
    
    /// Installs an unsequenced compatibility binding. It can only acquire a
    /// vacant slot or confirm its own existing socket; it cannot overwrite a
    /// sequenced P2P binding.
    @discardableResult
    public func setConnection(_ connection: NWConnection, for peerId: String) -> Bool {
        if let current = connections[peerId] {
            return current.leaseSequence == nil && current.connection === connection
        }
        connections[peerId] = ConnectionBinding(
            connection: connection,
            leaseSequence: nil
        )
        return true
    }

    /// Installs a P2P connection binding using the manager's monotonic lease
    /// sequence. A delayed actor hop from an older connection can never replace
    /// a newer binding for the same peer.
    @discardableResult
    public func setConnection(
        _ connection: NWConnection,
        for peerId: String,
        leaseSequence: UInt64
    ) -> Bool {
        if let current = connections[peerId],
           let currentSequence = current.leaseSequence {
            guard leaseSequence >= currentSequence else { return false }
            if leaseSequence == currentSequence {
                return current.connection === connection
            }
        }
        connections[peerId] = ConnectionBinding(
            connection: connection,
            leaseSequence: leaseSequence
        )
        return true
    }

    /// Returns a send capability only when the requested connection still owns
    /// the exact sequenced binding. Every send revalidates the same tuple.
    public func boundTransport(
        for peerId: String,
        expectedConnection: NWConnection,
        leaseSequence: UInt64
    ) throws -> BoundTransport {
        guard let current = connections[peerId],
              current.connection === expectedConnection,
              current.leaseSequence == leaseSequence else {
            throw NWConnectionTransportBindingError.staleBinding
        }
        return BoundTransport(
            owner: self,
            peerId: peerId,
            connection: expectedConnection,
            leaseSequence: leaseSequence
        )
    }
    
    /// Broad removal is limited to unsequenced compatibility bindings. P2P
    /// callers must release by exact socket (and preferably exact sequence).
    @discardableResult
    public func removeConnection(for peerId: String) -> Bool {
        guard let current = connections[peerId], current.leaseSequence == nil else {
            return false
        }
        connections.removeValue(forKey: peerId)
        return true
    }

    /// Compatibility release for an unsequenced binding owned by the expected
    /// socket. Sequenced P2P bindings must use the generation-aware overload.
    @discardableResult
    public func removeConnection(
        _ expectedConnection: NWConnection,
        for peerId: String
    ) -> Bool {
        guard let current = connections[peerId],
              current.leaseSequence == nil,
              current.connection === expectedConnection else {
            return false
        }
        connections.removeValue(forKey: peerId)
        return true
    }

    /// Removes a sequenced binding only when both socket and generation match.
    @discardableResult
    public func removeConnection(
        _ expectedConnection: NWConnection,
        for peerId: String,
        leaseSequence: UInt64
    ) -> Bool {
        guard let current = connections[peerId],
              current.connection === expectedConnection,
              current.leaseSequence == leaseSequence else {
            return false
        }
        connections.removeValue(forKey: peerId)
        return true
    }
    
    public func send(to peer: PeerIdentifier, data: Data) async throws {
        guard let binding = connections[peer.deviceId] else {
            throw NWConnectionTransportBindingError.connectionUnavailable
        }
        guard binding.leaseSequence == nil else {
            throw NWConnectionTransportBindingError.boundCapabilityRequired
        }
        try await send(data, over: binding.connection)
    }

    private func send(
        _ data: Data,
        to peerId: String,
        expectedConnection: NWConnection,
        leaseSequence: UInt64
    ) async throws {
        guard let current = connections[peerId],
              current.connection === expectedConnection,
              current.leaseSequence == leaseSequence else {
            throw NWConnectionTransportBindingError.staleBinding
        }
        try await send(data, over: expectedConnection)
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        // 与 macOS 端一致：TCP 流上做 4-byte big-endian length framing
        let framed = try P2PControlFramePolicy.frame(body: data)
        
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
