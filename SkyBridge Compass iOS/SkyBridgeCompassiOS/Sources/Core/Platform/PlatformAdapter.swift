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
        // 尝试从 Keychain 加载
        if let existingKey = try? loadIdentityKeyFromKeychain(algorithm: algorithm) {
            identityKeyHandle = existingKey.keyHandle
            identityPublicKey = existingKey.publicKey
            return
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
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                let privateKey = try MLDSA65.PrivateKey()
                let publicKey = privateKey.publicKey.rawRepresentation
                return (.softwareKey(privateKey.integrityCheckedRepresentation), publicKey)
            }
            #endif
            // Fallback to Ed25519
            let privateKey = Curve25519.Signing.PrivateKey()
            let publicKey = privateKey.publicKey.rawRepresentation
            return (.softwareKey(privateKey.rawRepresentation), publicKey)
        }
    }
    
    // MARK: - Keychain Helpers
    
    private func loadIdentityKeyFromKeychain(algorithm: ProtocolSigningAlgorithm) throws -> (keyHandle: SigningKeyHandle, publicKey: Data)? {
        let tag = "com.skybridge.identity.\(algorithm.rawValue)"
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let keyData = result as? Data else {
            return nil
        }
        
        // 解析存储的数据（格式: privateKey || publicKey）
        switch algorithm {
        case .ed25519:
            guard keyData.count >= 64 else { return nil }
            let privateKeyData = keyData.prefix(32)
            let publicKeyData = keyData.suffix(32)
            return (.softwareKey(Data(privateKeyData)), Data(publicKeyData))
            
        case .mlDSA65:
            #if HAS_APPLE_PQC_SDK
            if #available(iOS 26.0, macOS 26.0, *) {
                guard keyData.count >= 4032 + 1952 else { return nil }
                let privateKeyData = keyData.prefix(4032)
                let publicKeyData = keyData.suffix(1952)
                return (.softwareKey(Data(privateKeyData)), Data(publicKeyData))
            }
            #endif
            // Fallback to Ed25519 format
            guard keyData.count >= 64 else { return nil }
            let privateKeyData = keyData.prefix(32)
            let publicKeyData = keyData.suffix(32)
            return (.softwareKey(Data(privateKeyData)), Data(publicKeyData))
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
    
    // MARK: - Handshake API
    
    /// 创建握手驱动器
    public func createHandshakeDriver(transport: any DiscoveryTransport) throws -> HandshakeDriver {
        guard isInitialized,
              let provider = cryptoProvider,
              let sigProvider = signatureProvider,
              let keyHandle = identityKeyHandle,
              let publicKey = identityPublicKey else {
            throw SkyBridgeError.notInitialized
        }
        
        return HandshakeDriver(
            transport: transport,
            cryptoProvider: provider,
            protocolSignatureProvider: sigProvider,
            identityKeyHandle: keyHandle,
            sigAAlgorithm: sigProvider.signatureAlgorithm,
            identityPublicKey: publicKey,
            policy: handshakePolicy
        )
    }
    
    /// 执行握手（带自动回退）
    public func performHandshake(
        deviceId: String,
        transport: any DiscoveryTransport,
        preferPQC: Bool = true,
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
            
            let driver = HandshakeDriver(
                transport: transport,
                cryptoProvider: preparation.cryptoProvider,
                protocolSignatureProvider: preparation.signatureProvider,
                identityKeyHandle: keyHandle,
                sigAAlgorithm: preparation.sigAAlgorithm,
                identityPublicKey: publicKey,
                policy: self.handshakePolicy
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
        return sealed.combined!
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
