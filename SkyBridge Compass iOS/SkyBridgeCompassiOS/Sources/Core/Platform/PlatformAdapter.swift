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
import Security
#if canImport(OQSRAII)
import OQSRAII
#endif

@available(iOS 17.0, *)
struct ExistingReadOnlyProtocolIdentityMaterial: Sendable {
    let deviceId: String
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKey: Data
    let protocolSigningKeyHandle: SigningKeyHandle
}

@available(iOS 17.0, *)
enum ExistingReadOnlyIdentityMaterialProvider {
    enum MaterialError: LocalizedError, Equatable {
        case modeNotEnabled
        case missingPQCRequirement
        case invalidPQCRequirement(String)
        case missingExpectedPQCSuite
        case invalidExpectedPQCSuite(String)
        case missingCurrentPathDeviceId
        case signingAlgorithmMismatch
        case bindingMismatch
        case signingKeyValidationFailed
        case pqcProviderUnavailable
        case missingPQCIdentity

        var errorDescription: String? {
            switch self {
            case .modeNotEnabled:
                return "Existing-read-only identity mode is not enabled"
            case .missingPQCRequirement:
                return "Formal smoke PQC requirement is missing"
            case .invalidPQCRequirement:
                return "Formal smoke PQC requirement must be 0 or 1"
            case .missingExpectedPQCSuite:
                return "Formal smoke expected PQC suite is missing"
            case .invalidExpectedPQCSuite:
                return "Formal smoke expected PQC suite is unsupported"
            case .missingCurrentPathDeviceId:
                return "Existing current-path device identity is missing"
            case .signingAlgorithmMismatch:
                return "Current-path and handshake signing algorithms do not match"
            case .bindingMismatch:
                return "Current-path binding does not match canonical protocol identity"
            case .signingKeyValidationFailed:
                return "Existing protocol signing key pair is inconsistent"
            case .pqcProviderUnavailable:
                return "Required PQC provider is unavailable"
            case .missingPQCIdentity:
                return "Existing PQC identity material is missing"
            }
        }
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_ROLE"] != nil
            && ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_EXISTING_TRUST_ONLY"] == "1"
    }

    static func requirePQCFromEnvironment() throws -> Bool {
        guard isEnabled else { throw MaterialError.modeNotEnabled }
        guard let raw = ProcessInfo.processInfo.environment["SKYBRIDGE_SMOKE_REQUIRE_PQC"] else {
            throw MaterialError.missingPQCRequirement
        }
        switch raw {
        case "0": return false
        case "1": return true
        default: throw MaterialError.invalidPQCRequirement(raw)
        }
    }

    static func protocolSigningAlgorithm(requirePQC: Bool) -> ProtocolSigningAlgorithm {
        requirePQC ? .mlDSA65 : .ed25519
    }

    static func requiredPQCSuite(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> CryptoSuite {
        guard let raw = environment["SKYBRIDGE_SMOKE_EXPECTED_SUITE_WIRE_ID"] else {
            throw MaterialError.missingExpectedPQCSuite
        }
        switch raw {
        case "0x0101": return .mlkem768
        default: throw MaterialError.invalidExpectedPQCSuite(raw)
        }
    }

    static func requireExistingDeviceId(_ rawDeviceId: String?) throws -> String {
        guard let deviceId = rawDeviceId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !deviceId.isEmpty else {
            throw MaterialError.missingCurrentPathDeviceId
        }
        return deviceId
    }

    static func loadProtocolIdentity() async throws -> ExistingReadOnlyProtocolIdentityMaterial {
        let requirePQC = try requirePQCFromEnvironment()
        let algorithm = protocolSigningAlgorithm(requirePQC: requirePQC)
        let deviceId = try requireExistingDeviceId(KeychainManager.shared.loadDeviceId())
        guard let existingKey = try SkyBridgeiOSCore.loadExistingIdentityKeyReadOnly(
            algorithm: algorithm
        ) else {
            throw MaterialError.signingKeyValidationFailed
        }
        let publicKey = existingKey.publicKey
        let keyHandle = existingKey.keyHandle
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: algorithm)
        let validationMessage = Data("skybridge.existing-read-only.identity.v1".utf8)
        let signature = try await signatureProvider.sign(validationMessage, key: keyHandle)
        guard try await signatureProvider.verify(
            validationMessage,
            signature: signature,
            publicKey: publicKey
        ) else {
            throw MaterialError.signingKeyValidationFailed
        }
        return ExistingReadOnlyProtocolIdentityMaterial(
            deviceId: deviceId,
            protocolSigningAlgorithm: algorithm,
            protocolPublicKey: publicKey,
            protocolSigningKeyHandle: keyHandle
        )
    }

    static func requireBindingMatchesCanonicalIdentity(
        material: ExistingReadOnlyProtocolIdentityMaterial,
        deviceId: String,
        protocolSigningAlgorithm: ProtocolSigningAlgorithm,
        protocolPublicKey: Data
    ) throws {
        guard material.deviceId == deviceId,
              material.protocolSigningAlgorithm == protocolSigningAlgorithm,
              material.protocolPublicKey == protocolPublicKey else {
            throw MaterialError.bindingMismatch
        }
    }

    static func loadPQCIdentityPublicKeys() async throws -> [KEMPublicKeyInfo] {
        guard try requirePQCFromEnvironment() else { return [] }
        let suite = try requiredPQCSuite()
        let provider = CryptoProviderFactory.make(policy: .requirePQC)
        guard provider.supportedSuites.contains(suite) else {
            throw MaterialError.pqcProviderUnavailable
        }
        let (publicKey, _) = try await P2PKEMIdentityKeyStore.shared.getOrCreateIdentityKey(
            for: suite,
            provider: provider
        )
        guard !publicKey.isEmpty else { throw MaterialError.missingPQCIdentity }
        return [KEMPublicKeyInfo(suiteWireId: suite.wireId, publicKey: publicKey)]
    }
}

// MARK: - SkyBridgeiOSCore

/// SkyBridge iOS 核心
/// 提供统一的 PQC 安全通信接口
@available(iOS 17.0, *)
public final class SkyBridgeiOSCore: @unchecked Sendable {
    
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
    
    /// 握手策略
    public var handshakePolicy: HandshakePolicy = .default
    
    /// 初始化状态
    public private(set) var isInitialized: Bool = false
    
    /// The last selection policy used to initialize the core.
    /// We must support re-initialization when the user toggles "enforce PQC" / compatibility settings.
    private var currentSelectionPolicy: CryptoProviderFactory.SelectionPolicy?

    private static func randomAttemptIdBytes() -> Data {
        var bytes = [UInt8](repeating: 0, count: HandshakeSOAExtension.attemptIdLength)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Data(bytes)
    }
    
    // MARK: - Initialization
    
    private init() {}
    
    /// 初始化核心组件
    /// - Parameter policy: 加密策略
    public func initialize(policy: CryptoProviderFactory.SelectionPolicy = .preferPQC) async throws {
        // Idempotency by policy: callers may invoke initialize multiple times (app launch + connect + settings toggles).
        // If policy changed, we MUST reconfigure handshakePolicy/provider/signing keys to match paper semantics.
        if isInitialized, currentSelectionPolicy == policy {
            return
        }
        currentSelectionPolicy = policy

        SkyBridgeLogger.shared.info("🧩 SkyBridgeiOSCore.initialize(policy=\(String(describing: policy)))")
        
        switch policy {
        case .preferPQC:
            handshakePolicy = .default
        case .requirePQC:
            handshakePolicy = .strictPQC
        case .classicOnly:
            handshakePolicy = HandshakePolicy(requirePQC: false, allowClassicFallback: false, minimumTier: .classic)
        }
        SkyBridgeLogger.shared.info("🧩 HandshakePolicy: requirePQC=\(handshakePolicy.requirePQC ? "1" : "0"), allowClassicFallback=\(handshakePolicy.allowClassicFallback ? "1" : "0"), minimumTier=\(handshakePolicy.minimumTier.rawValue)")
        
        // 创建加密 Provider
        cryptoProvider = CryptoProviderFactory.make(policy: policy)
        
        // 创建签名 Provider
        let sigAlgorithm: ProtocolSigningAlgorithm = cryptoProvider?.tier == .classic ? .ed25519 : .mlDSA65
        signatureProvider = ProtocolSignatureProviderSelector.select(for: sigAlgorithm)
        
        // 生成或加载身份密钥
        try await loadOrCreateIdentityKey(algorithm: sigAlgorithm)
        
        isInitialized = true
    }
    
    // MARK: - Identity Key Management
    
    /// 加载或创建身份密钥
    private func loadOrCreateIdentityKey(algorithm: ProtocolSigningAlgorithm) async throws {
        if ExistingReadOnlyIdentityMaterialProvider.isEnabled {
            let material = try await ExistingReadOnlyIdentityMaterialProvider.loadProtocolIdentity()
            guard material.protocolSigningAlgorithm == algorithm else {
                throw ExistingReadOnlyIdentityMaterialProvider.MaterialError.signingAlgorithmMismatch
            }
            identityKeyHandle = material.protocolSigningKeyHandle
            identityPublicKey = material.protocolPublicKey
            return
        }

        // 尝试从 Keychain 加载
        if let existingKey = try? Self.loadExistingIdentityKeyReadOnly(algorithm: algorithm) {
            if await isIdentityKeyUsable(
                keyHandle: existingKey.keyHandle,
                publicKey: existingKey.publicKey,
                algorithm: algorithm
            ) {
                identityKeyHandle = existingKey.keyHandle
                identityPublicKey = existingKey.publicKey
                return
            }

            SkyBridgeLogger.shared.warning(
                "⚠️ 发现旧/不兼容身份密钥（algorithm=\(algorithm.rawValue)），将自动重建"
            )
        }
        
        // 创建新密钥
        let newKey = try await generateIdentityKey(algorithm: algorithm)
        identityKeyHandle = newKey.keyHandle
        identityPublicKey = newKey.publicKey
        
        // 保存到 Keychain
        try saveIdentityKeyToKeychain(keyHandle: newKey.keyHandle, publicKey: newKey.publicKey, algorithm: algorithm)
    }
    
    /// 生成身份密钥
    private func generateIdentityKey(algorithm: ProtocolSigningAlgorithm) async throws -> (keyHandle: SigningKeyHandle, publicKey: Data) {
        switch algorithm {
        case .ed25519:
            let privateKey = Curve25519.Signing.PrivateKey()
            let publicKey = privateKey.publicKey.rawRepresentation
            return (.softwareKey(privateKey.rawRepresentation), publicKey)
            
        case .mlDSA65:
            guard let provider = cryptoProvider, provider.tier != .classic else {
                throw SkyBridgeError.handshakeFailed(
                    reason: "ML-DSA identity key requested without PQC provider"
                )
            }
            // 避免在主线程执行 PQC 身份密钥生成（冷启动/首次监听会明显卡顿）。
            let keyPair = try await Task.detached(priority: .userInitiated) {
                try await provider.generateKeyPair(for: .signing)
            }.value
            return (.softwareKey(keyPair.privateKey.bytes), keyPair.publicKey.bytes)
        }
    }
    
    // MARK: - Keychain Helpers
    
    static func loadExistingIdentityKeyReadOnly(
        algorithm: ProtocolSigningAlgorithm
    ) throws -> (keyHandle: SigningKeyHandle, publicKey: Data)? {
        let tag = "com.skybridge.identity.\(algorithm.rawValue)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let matches = result as? [Data],
              matches.count == 1,
              let keyData = matches.first else {
            throw SkyBridgeError.handshakeFailed(
                reason: "Existing protocol identity is missing, ambiguous, or unreadable"
            )
        }
        
        // 解析存储的数据（格式: privateKey || publicKey）
        switch algorithm {
        case .ed25519:
            guard keyData.count == 64 else { return nil }
            let privateKeyData = keyData.prefix(32)
            let publicKeyData = keyData.suffix(32)
            return (.softwareKey(Data(privateKeyData)), Data(publicKeyData))
            
        case .mlDSA65:
            let publicKeyLength = mldsaPublicKeyLength()
            guard publicKeyLength > 0, keyData.count > publicKeyLength else { return nil }
            let privateKeyData = keyData.prefix(keyData.count - publicKeyLength)
            let publicKeyData = keyData.suffix(publicKeyLength)
            return (.softwareKey(Data(privateKeyData)), Data(publicKeyData))
        }
    }

    private static func mldsaPublicKeyLength() -> Int {
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

    private func isIdentityKeyUsable(
        keyHandle: SigningKeyHandle,
        publicKey: Data,
        algorithm: ProtocolSigningAlgorithm
    ) async -> Bool {
        guard let signatureProvider else { return false }
        guard signatureProvider.signatureAlgorithm == algorithm else { return false }

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
    
    private func saveIdentityKeyToKeychain(keyHandle: SigningKeyHandle, publicKey: Data, algorithm: ProtocolSigningAlgorithm) throws {
        let tag = "com.skybridge.identity.\(algorithm.rawValue)"
        
        guard case .softwareKey(let privateKeyData) = keyHandle else {
            return
        }
        
        // 存储格式: privateKey || publicKey
        var keyData = privateKeyData
        keyData.append(publicKey)
        
        // 删除已存在的
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        
        // 添加新的
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw SkyBridgeError.keychainError(status: status)
        }
    }

    private func supportsHandshakeSuite(
        _ suite: CryptoSuite,
        with provider: any CryptoProvider
    ) -> Bool {
        guard suite.isKnown else { return false }

        if suite.isHybrid {
            guard provider.tier == .nativePQC else { return false }
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                return AppleXWingCryptoProvider.quickRuntimeProbe()
            }
            #endif
            return false
        }

        if suite.isPQCGroup {
            return provider.tier != .classic
        }

        return provider.supportsSuite(suite)
    }

    private func resolvedHandshakeSuites(
        for provider: any CryptoProvider,
        offeredSuites: [CryptoSuite]? = nil,
        peerSupportedSuites: [CryptoSuite]? = nil
    ) -> [CryptoSuite] {
        if let offeredSuites, !offeredSuites.isEmpty {
            return offeredSuites.filter { supportsHandshakeSuite($0, with: provider) }
        }

        if let peerSupportedSuites, !peerSupportedSuites.isEmpty {
            let supported = peerSupportedSuites.filter { supportsHandshakeSuite($0, with: provider) }
            if !supported.isEmpty {
                return supported
            }
        }

        return [provider.activeSuite].filter { supportsHandshakeSuite($0, with: provider) }
    }
    
    // MARK: - Handshake API
    
    /// 创建握手驱动器
    public func createHandshakeDriver(
        transport: any DiscoveryTransport,
        offeredSuites: [CryptoSuite]? = nil,
        peerSupportedSuites: [CryptoSuite]? = nil,
        localSOAPeerId: Data? = nil,
        expectedRemoteSOAPeerId: Data? = nil,
        trustProvider: (any HandshakeTrustProvider)? = nil
    ) throws -> HandshakeDriver {
        guard isInitialized,
              let provider = cryptoProvider,
              let sigProvider = signatureProvider,
              let keyHandle = identityKeyHandle,
              let publicKey = identityPublicKey else {
            throw SkyBridgeError.notInitialized
        }

        let handshakeSuites = resolvedHandshakeSuites(
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
            expectedRemoteSOAPeerId: expectedRemoteSOAPeerId
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
        onDriverCreated: (@Sendable (HandshakeDriver) async -> Void)? = nil
    ) async throws -> SessionKeys {
        guard isInitialized,
              let provider = cryptoProvider,
              let keyHandle = identityKeyHandle,
              let publicKey = identityPublicKey else {
            throw SkyBridgeError.notInitialized
        }
        
        SkyBridgeLogger.shared.info(
            "🧩 performHandshake(policy): requirePQC=\(handshakePolicy.requirePQC ? "1" : "0"), " +
            "allowClassicFallback=\(handshakePolicy.allowClassicFallback ? "1" : "0"), " +
            "minimumTier=\(handshakePolicy.minimumTier.rawValue)"
        )

        return try await TwoAttemptHandshakeManager.performHandshakeWithPreparation(
            deviceId: deviceId,
            preferPQC: preferPQC,
            policy: handshakePolicy,
            cryptoProvider: provider
        ) { preparation in
            SkyBridgeLogger.shared.info(
                "🤝 Handshake attempt: strategy=\(preparation.strategy.rawValue), sigA=\(preparation.sigAAlgorithm.rawValue), " +
                "offeredSuites=\(preparation.offeredSuites.map { $0.rawValue }.joined(separator: ",")), " +
                "provider=\(preparation.cryptoProvider.providerName), activeSuite=\(preparation.cryptoProvider.activeSuite.rawValue), " +
                // Paper terminology alignment:
                "downgradeResistance=policy_gate+no_timeout_fallback+rate_limited, " +
                "policyInTranscript=1, transcriptBinding=1, " +
                "policyRequirePQC=\(self.handshakePolicy.requirePQC ? "1" : "0"), " +
                "policyAllowClassicFallback=\(self.handshakePolicy.allowClassicFallback ? "1" : "0"), " +
                "policyMinimumTier=\(self.handshakePolicy.minimumTier.rawValue), " +
                "policyRequireSecureEnclavePoP=\(self.handshakePolicy.requireSecureEnclavePoP ? "1" : "0")"
            )

            let attemptSOAMetadata: HandshakeSOAMetadata? = {
                guard let localSOAPeerId, let expectedRemoteSOAPeerId else {
                    return soaMetadata
                }
                return try? HandshakeSOAMetadata(
                    initiatorPeerId: localSOAPeerId,
                    targetPeerId: expectedRemoteSOAPeerId,
                    attemptId: Self.randomAttemptIdBytes()
                )
            }()

            let driver = HandshakeDriver(
                transport: transport,
                cryptoProvider: preparation.cryptoProvider,
                protocolSignatureProvider: preparation.signatureProvider,
                identityKeyHandle: keyHandle,
                sigAAlgorithm: preparation.sigAAlgorithm,
                identityPublicKey: publicKey,
                policy: self.handshakePolicy,
                cryptoPolicy: preparation.cryptoPolicy,
                offeredSuites: preparation.offeredSuites,
                trustProvider: trustProvider,
                soaMetadata: attemptSOAMetadata,
                localSOAPeerId: localSOAPeerId,
                expectedRemoteSOAPeerId: expectedRemoteSOAPeerId
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
    case handshakeFailed(reason: String)
    case encryptionFailed(reason: String)
    case decryptionFailed(reason: String)
    
    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "SkyBridge core not initialized"
        case .keychainError(let status):
            return "Keychain error: \(status)"
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
