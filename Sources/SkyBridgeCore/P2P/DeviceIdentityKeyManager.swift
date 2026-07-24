//
// DeviceIdentityKeyManager.swift
// SkyBridgeCore
//
// iOS/iPadOS P2P Integration - Device Identity Key Management
// Requirements: 4.1, 9.1
//
// 管理设备身份密钥：
// 1. 优先使用 Secure Enclave (kSecAttrTokenIDSecureEnclave)
// 2. 回退到 Keychain 存储
// 3. 支持密钥轮换策略
// 4. 非导出密钥策略
//

import Foundation
import CryptoKit
import Security
#if canImport(OQSRAII)
import OQSRAII
#endif

// MARK: - Device Identity Key Type

/// 设备身份密钥类型
public enum DeviceIdentityKeyType: String, Codable, Sendable {
 /// P-256 签名密钥（Secure Enclave 支持）
    case p256Signing = "P256-Signing"
    
 /// P-256 密钥协商密钥
    case p256KeyAgreement = "P256-KeyAgreement"
}

// MARK: - Device Identity Key Info

/// 设备身份密钥信息
public struct DeviceIdentityKeyInfo: Codable, Sendable, Equatable {
 /// 设备 ID
    public let deviceId: String
    
 /// 公钥指纹 (SHA-256 hex, 64 chars)
    public let pubKeyFP: String
    
 /// 公钥数据 (DER 编码)
    public let publicKey: Data
    
 /// 密钥类型
    public let keyType: DeviceIdentityKeyType
    
 /// 创建时间
    public let createdAt: Date
    
 /// 是否存储在 Secure Enclave
    public let isSecureEnclave: Bool
    
 /// 短 ID（用于 UI 显示，前 16 chars）
    public var shortId: String {
        String(pubKeyFP.prefix(P2PConstants.pubKeyFPDisplayLength))
    }
    
    public init(
        deviceId: String,
        pubKeyFP: String,
        publicKey: Data,
        keyType: DeviceIdentityKeyType,
        createdAt: Date = Date(),
        isSecureEnclave: Bool
    ) {
        self.deviceId = deviceId
        self.pubKeyFP = pubKeyFP
        self.publicKey = publicKey
        self.keyType = keyType
        self.createdAt = createdAt
        self.isSecureEnclave = isSecureEnclave
    }
}

// MARK: - KEM Identity Key Record

/// KEM 身份密钥记录（本地存储）
public struct KEMIdentityKeyRecord: Codable, Sendable, Equatable {
    public let suiteWireId: UInt16
    public let publicKey: Data
    public let privateKey: Data
    public let createdAt: Date
    
    public init(
        suiteWireId: UInt16,
        publicKey: Data,
        privateKey: Data,
        createdAt: Date = Date()
    ) {
        self.suiteWireId = suiteWireId
        self.publicKey = publicKey
        self.privateKey = privateKey
        self.createdAt = createdAt
    }
}


// MARK: - Device Identity Key Error

/// 设备身份密钥错误
public enum DeviceIdentityKeyError: Error, LocalizedError, Sendable {
    case keyGenerationFailed(String)
    case keyNotFound
    case keyAccessDenied
    case secureEnclaveNotAvailable
    case invalidKeyData
    case incompleteKeyMaterial(String)
    case keychainError(OSStatus)
    case signatureFailed(String)
    case verificationFailed
    case keyRotationFailed(String)
    case authorityConflict(String)
    case corruptIdentityAuthority(String)
    case identityMigrationRequiresRotationAndRepinning(String)
    
    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let reason):
            return "Key generation failed: \(reason)"
        case .keyNotFound:
            return "Device identity key not found"
        case .keyAccessDenied:
            return "Access to device identity key denied"
        case .secureEnclaveNotAvailable:
            return "Secure Enclave not available on this device"
        case .invalidKeyData:
            return "Invalid key data"
        case .incompleteKeyMaterial(let reason):
            return "Incomplete identity key material: \(reason)"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .signatureFailed(let reason):
            return "Signature failed: \(reason)"
        case .verificationFailed:
            return "Signature verification failed"
        case .keyRotationFailed(let reason):
            return "Key rotation failed: \(reason)"
        case .authorityConflict(let reason):
            return "Device identity authority conflict: \(reason)"
        case .corruptIdentityAuthority(let reason):
            return "Device identity authority is corrupt or incomplete: \(reason)"
        case .identityMigrationRequiresRotationAndRepinning(let reason):
            return "Device identity migration requires explicit rotation and peer re-pinning: \(reason)"
        }
    }
}

// MARK: - Device Identity Key Manager

/// 设备身份密钥管理器
///
/// 管理设备的长期身份密钥，用于 P2P 认证。
/// 优先使用 Secure Enclave 存储密钥（不可导出）。
@available(macOS 14.0, iOS 17.0, *)
public actor DeviceIdentityKeyManager {
    
 // MARK: - Singleton
    
 /// 共享实例
    public static let shared = DeviceIdentityKeyManager()
    
 // MARK: - Constants
    
    private enum KeychainConstants {
        static let service = "com.skybridge.p2p.identity"
        static let signingKeyTag = "com.skybridge.p2p.identity.signing"
        static let keyAgreementKeyTag = "com.skybridge.p2p.identity.keyagreement"
        static let deviceIdKey = "com.skybridge.p2p.deviceId"
        static let kemService = "com.skybridge.p2p.identity.kem"
        static let kemKeyPrefix = "kem_key_"
        
 // MARK: - Signature Mechanism Alignment ( 5.1, 5.2)
        
 /// Ed25519 协议签名密钥 tag
        static let protocolSigningKeyTag = "com.skybridge.p2p.identity.protocol.ed25519"
        
        /// Historical P-256 SE PoP tag. New code never creates or queries it;
        /// the validated unique-tag identity authority carries the PoP key.
        static let sePoPKeyTag = "com.skybridge.p2p.identity.pop.p256"
        
 // MARK: - ML-DSA-65 Protocol Signing Key ( 11.1, 11.2)
        
 /// ML-DSA-65 协议签名密钥 service
        static let mldsaService = "com.skybridge.p2p.identity.mldsa65"
        
 /// ML-DSA-65 公钥 account
        static let mldsaPublicKeyAccount = "mldsa65_publicKey"
        
        /// ML-DSA-65 私钥 account
        static let mldsaSecretKeyAccount = "mldsa65_secretKey"
        static let mldsaCanonicalKeyPairAccount = "mldsa65_keypair_v3"
        static let mldsaAlgorithmIdentifier = "ML-DSA-65"
        static let mldsaPublicKeyLength = 1_952
        static let mldsaPrivateKeyLength = 4_032
        static let mldsaSignatureLength = 3_309
        static let secureEnclaveMLDSAService = "com.skybridge.p2p.identity.protocol.secure-enclave.v1"
        static let mirroredDeviceIdDefaultsKey = "SkyBridge.P2P.DeviceIdentity.DeviceID"
        static let mirroredProtocolSigningPublicKeyDefaultsKey = "SkyBridge.P2P.DeviceIdentity.ProtocolSigningPublicKey"
        static let mirroredMLDSAPublicKeyDefaultsKey = "SkyBridge.P2P.DeviceIdentity.MLDSA65PublicKey"
        static let inMemorySigningPrivateKey = "com.skybridge.p2p.identity.signing.inmemory.private"
    }

    private nonisolated static var useInMemoryKeychain: Bool {
        #if DEBUG || SKYBRIDGE_TESTING
        let env = ProcessInfo.processInfo.environment
        if env["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
            || NSClassFromString("XCTest.XCTestCase") != nil
        #else
        return false
        #endif
    }
    private nonisolated(unsafe) static var inMemoryStore: [String: Data] = [:]
    private nonisolated static let inMemoryLock = NSLock()
    private nonisolated(unsafe) static var inMemoryKEMStore: [String: Data] = [:]
    private nonisolated static let inMemoryKEMLock = NSLock()

    private nonisolated static func inMemoryGet(_ key: String) -> Data? {
        inMemoryLock.lock()
        defer { inMemoryLock.unlock() }
        return inMemoryStore[key]
    }

    private nonisolated static func inMemorySet(_ data: Data, for key: String) {
        inMemoryLock.lock()
        inMemoryStore[key] = data
        inMemoryLock.unlock()
    }

    private func resolvedSharedIdentityKeychainScope() throws -> KeychainGenericPasswordScope {
        try effectiveSharedIdentityScopeSource.resolve()
    }

    /// The shipping singleton always requires the signed shared-access-group
    /// entitlement. SwiftPM XCTest processes cannot carry that entitlement, so
    /// their already-selected process-local backend receives an equally
    /// explicit synthetic scope instead of accidentally reaching production
    /// Keychain authority through one of the PQC helper layers.
    private var effectiveSharedIdentityScopeSource: SkyBridgeSharedIdentityScopeSource {
        #if DEBUG || SKYBRIDGE_TESTING
        if Self.useInMemoryKeychain {
            return .explicitForTesting(.inMemorySharedIdentityForTesting)
        }
        #endif
        return sharedIdentityScopeSource
    }
    
 // MARK: - Properties
    
 /// 缓存的密钥信息
    private var cachedKeyInfo: DeviceIdentityKeyInfo?
    
 /// 缓存的 KEM 公钥（按 suite wireId + provider tier）
    private var cachedKEMPublicKeys: [KEMCacheKey: Data] = [:]
    
 /// 缓存的 Ed25519 协议签名密钥
    private var cachedProtocolSigningKey: (publicKey: Data, privateKey: Data)?
    
    /// 缓存的 ML-DSA-65 协议签名密钥
    private var cachedMLDSASigningKey: (publicKey: Data, privateKey: Data)?
    private var cachedMLDSA87SigningIdentity: (publicKey: Data, keyHandle: SigningKeyHandle)?
    private var cachedSecureEnclaveMLDSAIdentities: [
        ProtocolSigningAlgorithm: SecureEnclaveMLDSAIdentityMaterial
    ] = [:]
    
    /// 设备 ID
    private var _deviceId: String?

    /// Tests use a namespaced in-memory slot so race and migration fixtures do
    /// not mutate the process-wide production singleton's cached identity.
    private let testingStorageNamespace: String?
    private let sharedIdentityScopeSource: SkyBridgeSharedIdentityScopeSource
    
 // MARK: - Initialization
    
    private init() {
        testingStorageNamespace = nil
        sharedIdentityScopeSource = .requiredEntitlement
    }

    #if DEBUG || SKYBRIDGE_TESTING
    internal init(
        testingStorageNamespace: String,
        keychainScope: KeychainGenericPasswordScope
    ) {
        precondition(!testingStorageNamespace.isEmpty)
        self.testingStorageNamespace = testingStorageNamespace
        self.sharedIdentityScopeSource = .explicitForTesting(keychainScope)
    }
    #endif

    private var mldsaStorageService: String {
        guard let testingStorageNamespace else {
            return KeychainConstants.mldsaService
        }
        return KeychainConstants.mldsaService + ".testing." + testingStorageNamespace
    }

    private var mldsaMirrorDefaultsKey: String {
        guard let testingStorageNamespace else {
            return KeychainConstants.mirroredMLDSAPublicKeyDefaultsKey
        }
        return KeychainConstants.mirroredMLDSAPublicKeyDefaultsKey + ".testing." + testingStorageNamespace
    }

    private var mldsaStoreIdentity: String {
        guard let testingStorageNamespace else {
            return "device-protocol-signing"
        }
        return "device-protocol-signing.testing.\(testingStorageNamespace)"
    }

    private var mldsaAuthorityDomain: PQCBackendAuthorityDomain {
        guard let testingStorageNamespace else { return .protocolIdentity }
        return .testing("device-protocol-signing.\(testingStorageNamespace)")
    }

    private var mldsa87StoreIdentity: String {
        guard let testingStorageNamespace else {
            return "device-protocol-signing-mldsa87"
        }
        return "device-protocol-signing-mldsa87.testing.\(testingStorageNamespace)"
    }

    private var secureEnclaveMLDSAService: String {
        guard let testingStorageNamespace else {
            return KeychainConstants.secureEnclaveMLDSAService
        }
        return KeychainConstants.secureEnclaveMLDSAService
            + ".testing."
            + testingStorageNamespace
    }

    private var mldsaStoreDescriptor: PQCKeyPairStoreDescriptor {
        PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: KeychainConstants.mldsaAlgorithmIdentifier,
            identity: mldsaStoreIdentity,
            authority: .active,
            authorityDomain: mldsaAuthorityDomain,
            storageScope: PQCKeyPairStoreStorageScope(
                canonicalLocation: KeychainGenericPasswordLocation(
                    service: mldsaStorageService,
                    account: KeychainConstants.mldsaCanonicalKeyPairAccount
                ),
                keychainScopeSource: effectiveSharedIdentityScopeSource,
                includeLegacyKeychain: true
            ),
            recordAlgorithmIdentifier: KeychainConstants.mldsaAlgorithmIdentifier
        )
    }

    private var mldsaLegacyKeyPair: PQCKeyPairStoreLegacyKeyPair {
        PQCKeyPairStoreLegacyKeyPair(
            publicKeyLocation: KeychainGenericPasswordLocation(
                service: mldsaStorageService,
                account: KeychainConstants.mldsaPublicKeyAccount
            ),
            privateKeyLocation: KeychainGenericPasswordLocation(
                service: mldsaStorageService,
                account: KeychainConstants.mldsaSecretKeyAccount
            ),
            keychainScopeSource: effectiveSharedIdentityScopeSource,
            includeLegacyKeychain: true
        )
    }
    
 // MARK: - Public Methods
    
 /// 获取或创建设备身份密钥
 /// - Returns: 密钥信息
    public func getOrCreateIdentityKey() async throws -> DeviceIdentityKeyInfo {
 // 检查缓存
        if Self.useInMemoryKeychain, let cached = cachedKeyInfo {
            return cached
        }
        
        do {
            if let existing = try await loadExistingKey() {
                cachedKeyInfo = existing
                return existing
            }
        } catch {
            let publicError = Self.publicIdentityError(for: error)
            SkyBridgeLogger.p2p.error(
                "❌ 加载设备身份密钥失败: \(publicError.localizedDescription, privacy: .public)"
            )
            throw publicError
        }
        
        do {
            let keyInfo = try await createNewIdentityKey()
            cachedKeyInfo = keyInfo
            return keyInfo
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }

    /// Returns the device ID bound to the immutable P-256 identity authority.
    ///
    /// This compatibility spelling remains throwing so callers cannot turn a
    /// missing, corrupt, or conflicting authority into an empty identity.
    public func getDeviceId() async throws -> String {
        try await getOrCreateDeviceIdStrict()
    }

    public func getOrCreateDeviceIdStrict() async throws -> String {
        if Self.useInMemoryKeychain, let deviceId = _deviceId {
            return deviceId
        }

        if Self.useInMemoryKeychain {
            if let stored = try loadStoredDeviceIdStrict() {
                _deviceId = stored
                return stored
            }
            let newId = UUID().uuidString
            try saveDeviceIdStrict(newId)
            _deviceId = newId
            return newId
        }

        // A device ID is one field of the immutable P-256 identity authority.
        // Persisting it independently would let app/extension first creation
        // publish different logical identities.
        return try await getOrCreateIdentityKey().deviceId
    }

    /// Loads the existing identity authority without creating one.
    ///
    /// `nil` means the authority is genuinely absent. Storage, validation, and
    /// migration failures remain typed errors and are never collapsed into
    /// absence.
    public func existingIdentityKeyInfoStrict() async throws -> DeviceIdentityKeyInfo? {
        if Self.useInMemoryKeychain, let cachedKeyInfo {
            return cachedKeyInfo
        }
        do {
            guard let existing = try await loadExistingKey() else { return nil }
            cachedKeyInfo = existing
            _deviceId = existing.deviceId
            return existing
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }

    /// Loads the device ID from an existing identity authority without creating
    /// identity material.
    public func existingDeviceIdStrict() async throws -> String? {
        try await existingIdentityKeyInfoStrict()?.deviceId
    }
    
 /// 使用身份密钥签名
 /// - Parameter data: 待签名数据
 /// - Returns: 签名
    public func sign(data: Data) async throws -> Data {
        let keyInfo = try await getOrCreateIdentityKey()

        if Self.useInMemoryKeychain {
            guard let privateKeyData = Self.inMemoryGet(KeychainConstants.inMemorySigningPrivateKey) else {
                throw DeviceIdentityKeyError.keyNotFound
            }
            do {
                let privateKey = try P256.Signing.PrivateKey(rawRepresentation: privateKeyData)
                let signature = try privateKey.signature(for: SHA256.hash(data: data))
                SkyBridgeLogger.p2p.debug("Signed data with in-memory identity key: \(keyInfo.shortId)")
                return signature.derRepresentation
            } catch {
                throw DeviceIdentityKeyError.invalidKeyData
            }
        }
        
 // 从 Keychain 获取私钥引用
        guard let privateKeyRef = try getPrivateKeyReference() else {
            throw DeviceIdentityKeyError.keyNotFound
        }
        
 // 执行签名
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKeyRef,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            &error
        ) else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw DeviceIdentityKeyError.signatureFailed(errorDesc)
        }
        
        SkyBridgeLogger.p2p.debug("Signed data with identity key: \(keyInfo.shortId)")
        return signature as Data
    }

    /// Prewarm identity material used by local P2P / current-path pairing so the first real connection
    /// does not block on first-touch keychain / key generation work.
    public func prewarmConnectionIdentityMaterials() async {
        do {
            _ = try await getOrCreateIdentityKey()
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Prewarm identity key failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        do {
            _ = try await getOrCreateProtocolSigningKey()
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Prewarm protocol signing key failed: \(error.localizedDescription, privacy: .public)"
            )
        }

        let provider = CryptoProviderFactory.make(policy: .preferPQC)
        do {
            _ = try await pairingIdentityKEMPublicKeys(using: provider)
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Prewarm pairing KEM identity keys failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
    
 /// 获取身份密钥句柄（Keychain/Secure Enclave）
    public func getSigningKeyHandle() async throws -> SigningKeyHandle {
        _ = try await getOrCreateIdentityKey()
        guard let privateKeyRef = try getPrivateKeyReference() else {
            throw DeviceIdentityKeyError.keyNotFound
        }
        return .secureEnclaveRef(privateKeyRef)
    }

 /// 获取 Secure Enclave 签名回调（不暴露私钥）
    public func getSigningCallback() async throws -> SigningCallback {
        _ = try await getOrCreateIdentityKey()
        return DeviceIdentityManagerSigningCallback(manager: self)
    }
    
 // MARK: - Protocol Signing Key (Ed25519) - 5.1
    
 /// 获取或创建 Ed25519 协议签名密钥
 ///
 /// 用于 sigA/sigB 主协议签名（Classic suite）。
 /// 存储在 Keychain（非 Secure Enclave，因为 SE 不支持 Ed25519）。
 ///
 /// **Requirements: 2.1, 2.2, 2.4**
    public func getOrCreateProtocolSigningKey() async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
 // 检查缓存
        if let cached = cachedProtocolSigningKey {
            return (publicKey: cached.publicKey, keyHandle: .softwareKey(cached.privateKey))
        }
        
 // 尝试从 Keychain 加载
        if let existing = try loadProtocolSigningKey() {
            cachedProtocolSigningKey = existing
            return (publicKey: existing.publicKey, keyHandle: .softwareKey(existing.privateKey))
        }
        
 // 创建新密钥
        let keyPair = try createProtocolSigningKey()
        cachedProtocolSigningKey = keyPair
        return (publicKey: keyPair.publicKey, keyHandle: .softwareKey(keyPair.privateKey))
    }
    
 /// 获取协议签名密钥句柄 (Ed25519)
 ///
 /// 用于 sigA/sigB 主协议签名。
 ///
 /// **Requirements: 2.4**
    public func getProtocolSigningKeyHandle() async throws -> SigningKeyHandle {
        let (_, keyHandle) = try await getOrCreateProtocolSigningKey()
        return keyHandle
    }
    
 /// 获取协议签名公钥 (Ed25519)
    public func getProtocolSigningPublicKey() async throws -> Data {
        let (publicKey, _) = try await getOrCreateProtocolSigningKey()
        return publicKey
    }
    
 // MARK: - Protocol Signing Key by Algorithm ( 11.1)
    
 /// 根据协议签名算法获取密钥句柄
 ///
 /// ** 11.1**: 统一入口，根据算法类型返回对应的密钥句柄
 /// - ed25519：沿用现有 rawRepresentation 存储
 /// - mlDSA65：OQS keypair 生成 + Keychain 存储
 ///
 /// **Requirements: 8.1, 8.6**
    public func getProtocolSigningKeyHandle(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> SigningKeyHandle {
        try await getProtocolSigningIdentity(
            for: algorithm,
            protection: .softwareKeychain
        ).keyHandle
    }

    /// Resolves the main-protocol signing identity under an explicit key
    /// protection policy. The policy is part of the identity authority; a
    /// Secure Enclave request never falls back to software.
    public func getProtocolSigningIdentity(
        for algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
        if protection == .secureEnclaveRequired {
            return try await getOrCreateSecureEnclaveMLDSAIdentity(for: algorithm)
        }
        switch algorithm {
        case .ed25519:
            let publicKey = try await getProtocolSigningPublicKey()
            let keyHandle = try await getProtocolSigningKeyHandle()
            return (publicKey, keyHandle)
        case .mlDSA65:
            return try await getOrCreateMLDSASigningKey()
        case .mlDSA87:
            return try await getOrCreateMLDSA87SigningIdentity()
        }
    }
    
 /// 根据协议签名算法获取公钥
 ///
 /// ** 11.1**: 统一入口，根据算法类型返回对应的公钥
 ///
 /// **Requirements: 8.1**
    public func getProtocolSigningPublicKey(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> Data {
        try await getProtocolSigningIdentity(
            for: algorithm,
            protection: .softwareKeychain
        ).publicKey
    }

    public func getProtocolSigningPublicKey(
        for algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> Data {
        try await getProtocolSigningIdentity(
            for: algorithm,
            protection: protection
        ).publicKey
    }

    /// 仅加载已存在的协议签名公钥；不会在缺失时补建 Keychain 条目。
    public func existingProtocolSigningPublicKey(
        for algorithm: ProtocolSigningAlgorithm
    ) async -> Data? {
        do {
            return try await existingProtocolSigningPublicKey(
                for: algorithm,
                protection: .softwareKeychain
            )
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ 非交互读取现有 \(algorithm.rawValue, privacy: .public) software 协议签名公钥失败: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// Loads one exact `(algorithm, protection)` authority without creating or
    /// switching key material. Software and Secure Enclave identities occupy
    /// independent immutable slots and may coexist during peer re-pinning.
    public func existingProtocolSigningPublicKey(
        for algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> Data? {
        switch protection {
        case .secureEnclaveRequired:
            return try loadSecureEnclaveMLDSARecord(for: algorithm)?.publicKey
        case .softwareKeychain:
            switch algorithm {
            case .ed25519:
                guard let existing = try loadProtocolSigningKey() else { return nil }
                cachedProtocolSigningKey = existing
                return existing.publicKey
            case .mlDSA65:
                guard let existing = try loadMLDSASigningKey() else { return nil }
                cachedMLDSASigningKey = existing
                return existing.publicKey
            case .mlDSA87:
                let persistedPublicKey = try OQSBridge.existingSigningPublicKey(
                    peerId: mldsa87StoreIdentity,
                    algorithm: .mldsa87,
                    authority: .active,
                    scopeSource: effectiveSharedIdentityScopeSource
                )
                guard let persistedPublicKey else { return nil }
                if let cachedMLDSA87SigningIdentity,
                   cachedMLDSA87SigningIdentity.publicKey != persistedPublicKey {
                    throw DeviceIdentityKeyError.authorityConflict(
                        "Cached ML-DSA-87 identity disagrees with its persisted authority"
                    )
                }
                return persistedPublicKey
            }
        }
    }

    /// Loads the complete signer from one exact committed authority slot.
    /// Unlike `getProtocolSigningIdentity`, this never provisions a missing key.
    public func existingProtocolSigningIdentity(
        for algorithm: ProtocolSigningAlgorithm,
        protection: ProtocolSigningKeyProtection
    ) async throws -> (publicKey: Data, keyHandle: SigningKeyHandle)? {
        switch protection {
        case .secureEnclaveRequired:
            guard let record = try loadSecureEnclaveMLDSARecord(for: algorithm) else {
                return nil
            }
            let material = try await restoreSecureEnclaveMLDSARecord(record)
            cachedSecureEnclaveMLDSAIdentities[algorithm] = material
            return (material.publicKey, .callback(material.signingCallback))

        case .softwareKeychain:
            switch algorithm {
            case .ed25519:
                guard let existing = try loadProtocolSigningKey() else { return nil }
                cachedProtocolSigningKey = existing
                return (existing.publicKey, .softwareKey(existing.privateKey))
            case .mlDSA65:
                guard let existing = try loadMLDSASigningKey() else { return nil }
                cachedMLDSASigningKey = existing
                return (existing.publicKey, .softwareKey(existing.privateKey))
            case .mlDSA87:
                guard let persistedPublicKey = try OQSBridge.existingSigningPublicKey(
                    peerId: mldsa87StoreIdentity,
                    algorithm: .mldsa87,
                    authority: .active,
                    scopeSource: effectiveSharedIdentityScopeSource
                ) else {
                    return nil
                }
                let resolved = try await OQSProtocolMLDSASigningCallback.resolve(
                    algorithm: .mlDSA87,
                    identity: mldsa87StoreIdentity,
                    scopeSource: effectiveSharedIdentityScopeSource
                )
                guard resolved.publicKey == persistedPublicKey else {
                    throw DeviceIdentityKeyError.authorityConflict(
                        "Resolved ML-DSA-87 signer disagrees with its persisted authority"
                    )
                }
                cachedMLDSA87SigningIdentity = resolved
                return resolved
            }
        }
    }
    
 // MARK: - SE PoP Key (P-256) - 5.2
    
 /// 获取 Secure Enclave PoP 密钥句柄 (P-256)
 ///
 /// 用于可选的 seSigA/seSigB Proof-of-Possession 签名。
 /// 如果 Secure Enclave 不可用，返回 nil。
 ///
 /// **Requirements: 2.3, 2.5**
    public func getSecureEnclaveKeyHandle() async throws -> SigningKeyHandle? {
        guard shouldUseSecureEnclaveForSigning() else {
            SkyBridgeLogger.p2p.info("Secure Enclave signing disabled by settings, using software fallback path")
            return nil
        }

        _ = try await getOrCreateIdentityKey()
        guard let secKey = try getSEPoPKeyReference() else { return nil }
        return .secureEnclaveRef(secKey)
    }
    
 /// 获取 Secure Enclave PoP 公钥 (P-256)
    public func getSecureEnclavePublicKey() async throws -> Data? {
        guard shouldUseSecureEnclaveForSigning() else { return nil }
        _ = try await getOrCreateIdentityKey()
        do {
            let store = try identityAuthorityStore()
            guard let authority = try DeviceIdentityAuthorityTransaction.resolve(
                using: store
            ), authority.isSecureEnclave else {
                return nil
            }
            return authority.publicKey
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }
    
 // MARK: - Key Migration - 5.3
    
    /// Migrates an exportable legacy fixed-tag P-256 identity into the shared
    /// immutable identity authority.
    ///
    /// The legacy key is copied under a unique shared-group tag before the
    /// add-only authority claim is attempted. Secure Enclave or otherwise
    /// unexportable legacy identities require explicit rotation and peer
    /// re-pinning. Repeated calls resolve the same authority winner.
    ///
    /// **Requirements: 5.4**
    public func migrateExistingIdentityKey() async throws {
        // Tests run with SKYBRIDGE_KEYCHAIN_IN_MEMORY=1 to avoid touching the system Keychain.
        // In this mode, identity-key migration is a no-op by design.
        if Self.useInMemoryKeychain { return }

        // Loading performs the only supported legacy transition: an exportable
        // software fixed-tag identity is copied under a unique shared tag and
        // then elected through the add-only authority CAS. Legacy Secure
        // Enclave material throws an explicit rotation/re-pin error.
        do {
            _ = try await loadExistingKey()
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }
    
 /// 识别密钥用途
 ///
 /// - Parameter tag: 密钥 tag
 /// - Returns: 密钥用途
    public func identifyKeyPurpose(tag: String) -> KeyPurpose {
        if tag.hasPrefix(DeviceIdentityAuthorityRecord.privateKeyTagPrefix) {
            return .identity
        }
        switch tag {
        case KeychainConstants.signingKeyTag:
            return .legacy  // 旧 P-256 身份密钥（迁移前）
        case KeychainConstants.protocolSigningKeyTag:
            return .protocol  // Ed25519 协议签名密钥
        case KeychainConstants.sePoPKeyTag:
            return .pop  // P-256 SE PoP 密钥（迁移后）
        default:
            return .unknown
        }
    }

 /// 获取或创建 KEM 身份密钥（用于 PQC 套件）
    public func getOrCreateKEMIdentityKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> (publicKey: Data, privateKey: SecureBytes) {
        let storageSuite = suite.canonicalKEMSuite
        guard provider.supportsSuite(storageSuite) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "\(provider.providerName) does not support \(storageSuite.rawValue)"
            )
        }
        let cacheKey = KEMCacheKey(suiteWireId: storageSuite.wireId, tier: provider.tier)
        if cachedKEMPublicKeys[cacheKey] != nil {
            if let record = try loadKEMKeyRecord(suiteWireId: storageSuite.wireId, tier: provider.tier) {
                cachedKEMPublicKeys[cacheKey] = record.publicKey
                return (publicKey: record.publicKey, privateKey: SecureBytes(data: record.privateKey))
            }
            cachedKEMPublicKeys.removeValue(forKey: cacheKey)
        }
        
        if let record = try loadKEMKeyRecord(suiteWireId: storageSuite.wireId, tier: provider.tier) {
            cachedKEMPublicKeys[cacheKey] = record.publicKey
            return (publicKey: record.publicKey, privateKey: SecureBytes(data: record.privateKey))
        }
        
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        guard keyPair.publicKey.usage == .keyExchange else {
            throw CryptoProviderError.keyUsageMismatch(
                expected: .keyExchange,
                actual: keyPair.publicKey.usage
            )
        }
        guard keyPair.privateKey.usage == .keyExchange else {
            throw CryptoProviderError.keyUsageMismatch(
                expected: .keyExchange,
                actual: keyPair.privateKey.usage
            )
        }
        guard keyPair.publicKey.suite.canonicalKEMSuite.wireId == storageSuite.wireId,
              keyPair.privateKey.suite.canonicalKEMSuite.wireId == storageSuite.wireId else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "\(provider.providerName) generated key material for a different KEM suite"
            )
        }
        let record = KEMIdentityKeyRecord(
            suiteWireId: storageSuite.wireId,
            publicKey: keyPair.publicKey.bytes,
            privateKey: keyPair.privateKey.bytes
        )
        try validateKEMRecord(record, suiteWireId: storageSuite.wireId, tier: provider.tier)
        let winner = try saveKEMKeyRecord(
            record,
            tier: provider.tier,
            conflictPolicy: .adoptWinner
        )
        cachedKEMPublicKeys[cacheKey] = winner.publicKey
        return (
            publicKey: winner.publicKey,
            privateKey: SecureBytes(data: winner.privateKey)
        )
    }
    
 /// 获取 KEM 身份公钥（不存在则创建）
    public func getKEMPublicKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> Data {
        let record = try await getOrCreateKEMIdentityKey(for: suite, provider: provider)
        return record.publicKey
    }

    public nonisolated static func pairingIdentityAdvertisedPQCSuites(
        using provider: any CryptoProvider
    ) -> [CryptoSuite] {
        pairingIdentityAdvertisedPQCSuites(
            using: provider,
            appleXWingAvailable: isAppleXWingAvailable(),
            qPeriaptEnabled: false,
            activeProtocolSigningAlgorithm: nil
        )
    }

    public nonisolated static func pairingIdentityAdvertisedPQCSuites(
        using provider: any CryptoProvider,
        activeProtocolSigningAlgorithm: ProtocolSigningAlgorithm,
        qPeriaptEnabled: Bool
    ) -> [CryptoSuite] {
        pairingIdentityAdvertisedPQCSuites(
            using: provider,
            appleXWingAvailable: isAppleXWingAvailable(),
            qPeriaptEnabled: qPeriaptEnabled,
            activeProtocolSigningAlgorithm: activeProtocolSigningAlgorithm
        )
    }

    public nonisolated static func pairingIdentityAdvertisedPQCSuites(
        using provider: any CryptoProvider,
        appleXWingAvailable: Bool,
        qPeriaptEnabled: Bool = false,
        activeProtocolSigningAlgorithm: ProtocolSigningAlgorithm? = nil
    ) -> [CryptoSuite] {
        // Q-Periapt has an additional authenticated-runtime admission gate. Do
        // not let a provider's broad capability list bypass that product gate.
        var suites = provider.supportedSuites.filter {
            $0.isPQCGroup
                && $0.isNegotiable
                && $0.wireId != CryptoSuite.qperiaptABI2PolicyBound.wireId
        }

        if qPeriaptEnabled, activeProtocolSigningAlgorithm == .mlDSA65 {
            suites.append(.qperiaptABI2PolicyBound)
        }

        if provider.tier == .nativePQC {
            if appleXWingAvailable {
                suites.append(.xwingMLDSA)
            }
            suites.append(.mlkem768MLDSA65)
            suites.append(.mlkem768MLDSA65FS)
        }

        let dedupedByWire = suites.reduce(into: [UInt16: CryptoSuite]()) { partialResult, suite in
            partialResult[suite.wireId] = suite
        }
        return dedupedByWire.values.sorted { $0.wireId < $1.wireId }
    }

    private nonisolated static func isAppleXWingAvailable() -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(macOS 26.0, iOS 26.0, *) {
            return AppleXWingCryptoProvider.selfTest()
        }
        #endif
        return false
    }

    public func pairingIdentityKEMPublicKeys(
        using provider: any CryptoProvider,
        limitingTo requestedSuites: [CryptoSuite]? = nil
    ) async throws -> [KEMPublicKeyInfo] {
        let activeIdentity = try await CommittedLocalProtocolIdentitySnapshot.loadActive(
            keyManager: self
        )
        let frozenQPeriaptProvider: QPeriaptCryptoProvider?
        if activeIdentity.algorithm == .mlDSA65,
           QPeriaptPlatformPolicy.isEnabledForLocalRuntime() {
            frozenQPeriaptProvider = QPeriaptPlatformPolicy.makeCryptoProvider()
        } else {
            frozenQPeriaptProvider = nil
        }
        var suites = Self.pairingIdentityAdvertisedPQCSuites(
            using: provider,
            activeProtocolSigningAlgorithm: activeIdentity.algorithm,
            qPeriaptEnabled: frozenQPeriaptProvider != nil
        )
        if let requestedSuites {
            let requestedWireIds = Set(requestedSuites.map(\.wireId))
            suites = suites.filter { requestedWireIds.contains($0.wireId) }
        }
        guard !suites.isEmpty else { return [] }

        var requiredWireIds = Set(
            provider.supportedSuites
                .filter { $0.isPQCGroup && $0.isNegotiable }
                .map(\.wireId)
        )
        if frozenQPeriaptProvider != nil,
           suites.contains(where: {
               $0.wireId == CryptoSuite.qperiaptABI2PolicyBound.wireId
           }) {
            requiredWireIds.insert(CryptoSuite.qperiaptABI2PolicyBound.wireId)
        }
        var kemKeys: [KEMPublicKeyInfo] = []
        kemKeys.reserveCapacity(suites.count)

        for suite in suites {
            let suiteProvider = try Self.pairingIdentityProvider(
                for: suite,
                baseProvider: provider,
                qPeriaptProvider: frozenQPeriaptProvider
            )
            do {
                let publicKey = try await getKEMPublicKey(for: suite, provider: suiteProvider)
                kemKeys.append(KEMPublicKeyInfo(suiteWireId: suite.wireId, publicKey: publicKey))
            } catch {
                if requiredWireIds.contains(suite.wireId) {
                    throw error
                }
                SkyBridgeLogger.p2p.warning(
                    "⚠️ pairingIdentity 互操作 KEM 公钥准备失败（suite=\(suite.rawValue, privacy: .public)）：\(error.localizedDescription, privacy: .public)"
                )
            }
        }

        return kemKeys
    }

    private nonisolated static func pairingIdentityProvider(
        for suite: CryptoSuite,
        baseProvider: any CryptoProvider,
        qPeriaptProvider: QPeriaptCryptoProvider?
    ) throws -> any CryptoProvider {
        if suite == .qperiaptABI2PolicyBound {
            guard let qPeriaptProvider else {
                throw CryptoProviderError.providerNotAvailable(.qPeriapt)
            }
            return qPeriaptProvider
        }

        #if HAS_APPLE_PQC_SDK
        if baseProvider.tier == .nativePQC {
            if #available(iOS 26.0, macOS 26.0, *) {
                if suite == .xwingMLDSA {
                    return AppleXWingCryptoProvider()
                }
                if suite.isPQCGroup {
                    return ApplePQCCryptoProvider()
                }
            }
        }
        #endif
        return baseProvider
    }
    
 /// 验证签名
 /// - Parameters:
 /// - data: 原始数据
 /// - signature: 签名
 /// - publicKey: 公钥（DER 编码）
 /// - Returns: 是否验证通过
    public func verify(data: Data, signature: Data, publicKey: Data) async throws -> Bool {
 // 从 DER 数据创建公钥
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic
        ]
        
        var error: Unmanaged<CFError>?
        guard let publicKeyRef = SecKeyCreateWithData(
            publicKey as CFData,
            attributes as CFDictionary,
            &error
        ) else {
            throw DeviceIdentityKeyError.invalidKeyData
        }
        
 // 验证签名
        let isValid = SecKeyVerifySignature(
            publicKeyRef,
            .ecdsaSignatureMessageX962SHA256,
            data as CFData,
            signature as CFData,
            &error
        )
        
        return isValid
    }
    
 /// 检查 Secure Enclave 是否可用
    public func isSecureEnclaveAvailable() -> Bool {
        #if targetEnvironment(simulator)
        return false
        #else
 // 检查设备是否支持 Secure Enclave
 // 通过尝试创建 SecAccessControl 来验证
        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &error
        )
        
        return access != nil && error == nil
        #endif
    }

    
 /// 轮换密钥
 /// - Returns: 新的密钥信息
    public func rotateKey() async throws -> DeviceIdentityKeyInfo {
        // Replacing the add-only cross-process authority requires a durable
        // staged cutover plus explicit peer re-pinning. Deleting the old claim
        // before publishing a replacement creates a crash window with no
        // identity authority, so the current release refuses that unsafe path.
        throw DeviceIdentityKeyError.keyRotationFailed(
            "Cross-process identity rotation requires an explicit staged cutover and peer re-pinning; the existing authority was preserved"
        )
    }
    
 /// 删除身份密钥
    public func deleteIdentityKey() throws {
        throw DeviceIdentityKeyError.keyRotationFailed(
            "Deleting the immutable cross-process identity requires an explicit reset transaction, peer trust removal, and re-pinning; the existing authority was preserved"
        )
    }
    
 // MARK: - Private Methods
    
    /// 创建新的身份密钥
    private func createNewIdentityKey() async throws -> DeviceIdentityKeyInfo {
        if Self.useInMemoryKeychain {
            let deviceId = try await getOrCreateDeviceIdStrict()
            let privateKey = P256.Signing.PrivateKey()
            let publicKeyData = privateKey.publicKey.x963Representation
            Self.inMemorySet(privateKey.rawRepresentation, for: KeychainConstants.inMemorySigningPrivateKey)
            let keyInfo = DeviceIdentityKeyInfo(
                deviceId: deviceId,
                pubKeyFP: computePublicKeyFingerprint(publicKeyData),
                publicKey: publicKeyData,
                keyType: .p256Signing,
                isSecureEnclave: false
            )
            try saveKeyInfo(keyInfo)
            SkyBridgeLogger.p2p.info("Created new in-memory device identity key: \(keyInfo.shortId)")
            return keyInfo
        }

        let store = try identityAuthorityStore()
        let deviceId = UUID().uuidString
        let preferSecureEnclave = shouldUseSecureEnclaveForSigning()
        var useSecureEnclave = preferSecureEnclave && isSecureEnclaveAvailable()
        if preferSecureEnclave && !useSecureEnclave {
            SkyBridgeLogger.p2p.warning("Secure Enclave signing requested but unavailable, falling back to software key")
        }
        if !preferSecureEnclave {
            SkyBridgeLogger.p2p.info("Secure Enclave signing disabled by settings, generating software key")
        }

        var candidateTag = DeviceIdentityAuthorityRecord.uniquePrivateKeyApplicationTag()
        let privateKey: SecKey
        do {
            privateKey = try store.createRandomPrivateKey(
                applicationTag: candidateTag,
                useSecureEnclave: useSecureEnclave
            )
        } catch {
            if useSecureEnclave, shouldFallbackIdentityKeyToSoftware(error: error) {
                SkyBridgeLogger.p2p.warning(
                    "⚠️ Identity key Secure Enclave creation failed (likely missing entitlement); falling back to software keychain key."
                )
                try store.deletePrivateKey(applicationTag: candidateTag)
                useSecureEnclave = false
                candidateTag = DeviceIdentityAuthorityRecord.uniquePrivateKeyApplicationTag()
                privateKey = try store.createRandomPrivateKey(
                    applicationTag: candidateTag,
                    useSecureEnclave: false
                )
            } else {
                throw error
            }
        }

        _ = privateKey
        let metadata: DeviceIdentityPrivateKeyMetadata?
        do {
            metadata = try store.privateKeyMetadata(
                forPrivateKeyApplicationTag: candidateTag
            )
        } catch {
            try store.deletePrivateKey(applicationTag: candidateTag)
            throw error
        }
        guard let metadata else {
            try store.deletePrivateKey(applicationTag: candidateTag)
            throw DeviceIdentityAuthorityError.authorityWinnerKeyMissing(candidateTag)
        }
        let candidate = DeviceIdentityAuthorityRecord(
            deviceId: deviceId,
            publicKey: metadata.publicKey,
            publicKeyFingerprint: DeviceIdentityAuthorityRecord.fingerprint(
                for: metadata.publicKey
            ),
            privateKeyApplicationTag: candidateTag,
            isSecureEnclave: metadata.isSecureEnclave,
            createdAt: Date()
        )
        let winner = try DeviceIdentityAuthorityTransaction.claimCandidate(
            candidate,
            using: store
        )
        let keyInfo = keyInfo(from: winner)
        publishResolvedIdentity(winner)
        SkyBridgeLogger.p2p.info(
            "Created or joined device identity authority: \(keyInfo.shortId), Secure Enclave: \(winner.isSecureEnclave)"
        )
        return keyInfo
    }

    private func shouldFallbackIdentityKeyToSoftware(error: Error) -> Bool {
        guard case DeviceIdentityKeyError.secureEnclaveNotAvailable = error else {
            return false
        }
        return true
    }

    nonisolated static func publicIdentityError(
        for error: Error
    ) -> DeviceIdentityKeyError {
        guard let authorityError = error as? DeviceIdentityAuthorityError else {
            return error as? DeviceIdentityKeyError
                ?? .corruptIdentityAuthority(error.localizedDescription)
        }
        switch authorityError {
        case .legacySecureEnclaveRequiresRotationAndRepinning,
             .legacyPrivateKeyNotExportableRequiresRotationAndRepinning:
            return .identityMigrationRequiresRotationAndRepinning(
                authorityError.localizedDescription
            )
        case .legacyIdentityConflictsWithAuthority,
             .immutableGenericPasswordConflict,
             .candidateKeyPublicKeyMismatch,
             .candidateCleanupFailed:
            return .authorityConflict(authorityError.localizedDescription)
        case .unsupportedRecordVersion,
             .invalidDeviceId,
             .invalidPublicKey,
             .publicKeyFingerprintMismatch,
             .invalidPrivateKeyApplicationTag,
             .invalidCreatedAt,
             .corruptAuthorityRecord,
             .authorityWinnerMissing,
             .authorityWinnerKeyMissing,
             .authorityWinnerPublicKeyMismatch,
             .authorityWinnerSecureEnclaveMismatch,
             .legacyIdentityIncomplete:
            return .corruptIdentityAuthority(authorityError.localizedDescription)
        }
    }

    private func shouldUseSecureEnclaveForSigning() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "Settings.UseSecureEnclaveMLDSA") == nil {
            return true
        }
        return defaults.bool(forKey: "Settings.UseSecureEnclaveMLDSA")
    }
    
 /// 加载现有密钥
    private func loadExistingKey() async throws -> DeviceIdentityKeyInfo? {
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + "keyInfo"
            let data = Self.inMemoryGet(key)
            guard let data else { return nil }
            return try JSONDecoder().decode(DeviceIdentityKeyInfo.self, from: data)
        }

        let store = try identityAuthorityStore()
        let legacy = try discoverLegacyIdentity(using: store)
        if let authority = try DeviceIdentityAuthorityTransaction.resolve(using: store) {
            let reconciled = try DeviceIdentityLegacyReconciliation.reconcile(
                legacy.state,
                with: authority,
                cleanup: {
                    try cleanupLegacyIdentity(legacy, using: store)
                }
            )
            publishResolvedIdentity(reconciled)
            return keyInfo(from: reconciled)
        }
        guard !legacy.state.isEmpty else {
            return nil
        }
        let migrated = try migrateLegacyIdentity(legacy, using: store)
        publishResolvedIdentity(migrated)
        return keyInfo(from: migrated)
    }
    
 /// 获取私钥引用
    private func getPrivateKeyReference() throws -> SecKey? {
        if Self.useInMemoryKeychain { return nil }
        do {
            let store = try identityAuthorityStore()
            guard let authority = try DeviceIdentityAuthorityTransaction.resolve(
                using: store
            ) else {
                return nil
            }
            return try store.loadAuthoritativePrivateKey(
                applicationTag: authority.privateKeyApplicationTag
            )
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }
    
 /// 保存密钥信息
    private func saveKeyInfo(_ keyInfo: DeviceIdentityKeyInfo) throws {
        let data = try JSONEncoder().encode(keyInfo)

        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + "keyInfo"
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return
        }

        throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
            "keyInfo cannot be persisted independently of the identity authority"
        )
    }

    private func identityAuthorityStore() throws -> DeviceIdentityKeychainAuthorityStore {
        try DeviceIdentityKeychainAuthorityStore(
            keychainScope: resolvedSharedIdentityKeychainScope()
        )
    }

    private func keyInfo(
        from authority: DeviceIdentityAuthorityRecord
    ) -> DeviceIdentityKeyInfo {
        DeviceIdentityKeyInfo(
            deviceId: authority.deviceId,
            pubKeyFP: authority.publicKeyFingerprint,
            publicKey: authority.publicKey,
            keyType: .p256Signing,
            createdAt: authority.createdAt,
            isSecureEnclave: authority.isSecureEnclave
        )
    }

    private func publishResolvedIdentity(_ authority: DeviceIdentityAuthorityRecord) {
        let resolvedKeyInfo = keyInfo(from: authority)
        cachedKeyInfo = resolvedKeyInfo
        _deviceId = authority.deviceId
        saveMirroredDeviceId(authority.deviceId)
    }

    private struct LegacyIdentityDiscovery {
        let privateKeys: [DeviceIdentityLegacyPrivateKeyCandidate]
        var keyInfoItems: [LegacyGenericPasswordCandidate]
        var deviceIdItems: [LegacyGenericPasswordCandidate]
        let state: DeviceIdentityLegacyState
    }

    private func discoverLegacyIdentity(
        using store: DeviceIdentityKeychainAuthorityStore
    ) throws -> LegacyIdentityDiscovery {
        let privateKeys = try store.loadLegacyPrivateKeyCandidates(
            applicationTag: KeychainConstants.signingKeyTag
        )
        let keyInfoItems = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
            service: KeychainConstants.service,
            account: "keyInfo",
            includeLegacyKeychain: true
        )
        let deviceIdItems = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
            service: KeychainConstants.service,
            account: KeychainConstants.deviceIdKey,
            includeLegacyKeychain: true
        )
        let keyInfos: [DeviceIdentityKeyInfo] = try keyInfoItems.map { item in
            do {
                return try JSONDecoder().decode(
                    DeviceIdentityKeyInfo.self,
                    from: item.data
                )
            } catch {
                throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                    "keyInfo is not decodable"
                )
            }
        }
        let deviceIds: [String] = try deviceIdItems.map { item in
            guard let value = String(data: item.data, encoding: .utf8),
                  !value.isEmpty,
                  value == value.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ) else {
                throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                    "deviceId is not valid UTF-8 identity data"
                )
            }
            return value
        }
        return LegacyIdentityDiscovery(
            privateKeys: privateKeys,
            keyInfoItems: keyInfoItems,
            deviceIdItems: deviceIdItems,
            state: DeviceIdentityLegacyState(
                keyInfos: keyInfos,
                deviceIds: deviceIds,
                privateKeyMetadata: privateKeys.map(\.metadata)
            )
        )
    }

    private func migrateLegacyIdentity(
        _ legacy: LegacyIdentityDiscovery,
        using store: DeviceIdentityKeychainAuthorityStore
    ) throws -> DeviceIdentityAuthorityRecord {
        let legacyKeyInfo = try DeviceIdentityLegacyReconciliation
            .migrationKeyInfo(from: legacy.state)
        guard let sourceKey = legacy.privateKeys.first else {
            throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                "fixed-tag private key is missing"
            )
        }
        var privateKeyRepresentation = try store.exportLegacyPrivateKey(
            sourceKey
        )
        defer { privateKeyRepresentation.secureErase() }

        let candidateTag = DeviceIdentityAuthorityRecord.uniquePrivateKeyApplicationTag()
        let legacyAuthority = DeviceIdentityAuthorityRecord(
            deviceId: legacyKeyInfo.deviceId,
            publicKey: legacyKeyInfo.publicKey,
            publicKeyFingerprint: legacyKeyInfo.pubKeyFP,
            privateKeyApplicationTag: candidateTag,
            isSecureEnclave: false,
            createdAt: legacyKeyInfo.createdAt
        )
        let winner = try DeviceIdentityAuthorityTransaction.migrateLegacy(
            .software(
                authority: legacyAuthority,
                privateKeyRepresentation: privateKeyRepresentation
            ),
            candidateApplicationTag: candidateTag,
            using: store
        )
        try cleanupLegacyIdentity(legacy, using: store)
        return winner
    }

    private func cleanupLegacyIdentity(
        _ legacy: LegacyIdentityDiscovery,
        using store: DeviceIdentityKeychainAuthorityStore
    ) throws {
        for key in legacy.privateKeys {
            try store.deleteLegacyPrivateKey(at: key.location)
        }
        for item in legacy.keyInfoItems {
            try KeychainManager.shared
                .deleteLegacyGenericPasswordCandidate(item)
        }
        for item in legacy.deviceIdItems {
            try KeychainManager.shared
                .deleteLegacyGenericPasswordCandidate(item)
        }
    }

 /// 加载 KEM 身份密钥记录（按 suite + provider tier）
    private func loadKEMKeyRecord(suiteWireId: UInt16, tier: CryptoTier) throws -> KEMIdentityKeyRecord? {
        let tierAccount = kemAccount(suiteWireId: suiteWireId, tier: tier)
        let currentRecord = try loadKEMKeyRecord(
            account: tierAccount,
            suiteWireId: suiteWireId,
            tier: tier
        )

        // Legacy records omitted the provider tier. They remain migration
        // inputs even after a tiered winner exists so a competing old identity
        // cannot be ignored on retry.
        let legacyAccount = kemAccount(suiteWireId: suiteWireId, tier: nil)
        let legacyRecord = try loadKEMKeyRecord(
            account: legacyAccount,
            suiteWireId: suiteWireId,
            tier: tier
        )
        if let currentRecord {
            try validateKEMRecord(
                currentRecord,
                suiteWireId: suiteWireId,
                tier: tier
            )
            if let legacyRecord {
                guard legacyRecord == currentRecord else {
                    throw DeviceIdentityAuthorityError
                        .immutableGenericPasswordConflict(
                            service: KeychainConstants.kemService,
                            account: legacyAccount
                        )
                }
                try deleteGenericPasswordItems(
                    service: KeychainConstants.kemService,
                    account: legacyAccount
                )
            }
            return currentRecord
        }

        if let legacyRecord {
            guard kemRecordMatchesProvider(
                legacyRecord,
                suiteWireId: suiteWireId,
                tier: tier
            ) else {
                throw DeviceIdentityAuthorityError
                    .immutableGenericPasswordConflict(
                        service: KeychainConstants.kemService,
                        account: legacyAccount
                    )
            }
            let winner = try saveKEMKeyRecord(
                legacyRecord,
                tier: tier,
                conflictPolicy: .requireExactCandidate
            )
            try deleteGenericPasswordItems(
                service: KeychainConstants.kemService,
                account: legacyAccount
            )
            return winner
        }
        return nil
    }

    private func deleteGenericPasswordItems(
        service: String,
        account: String
    ) throws {
        if Self.useInMemoryKeychain, service == KeychainConstants.kemService {
            Self.inMemoryKEMLock.withLock {
                _ = Self.inMemoryKEMStore.removeValue(
                    forKey: service + "|" + account
                )
            }
            return
        }
        let candidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: service,
                account: account,
                includeLegacyKeychain: true
            )
        for candidate in candidates {
            try KeychainManager.shared
                .deleteLegacyGenericPasswordCandidate(candidate)
        }
    }
    
 /// 保存 KEM 身份密钥记录（按 suite + provider tier）
    private enum ImmutableCandidateConflictPolicy: Equatable {
        case adoptWinner
        case requireExactCandidate
    }

    private func saveKEMKeyRecord(
        _ record: KEMIdentityKeyRecord,
        tier: CryptoTier,
        conflictPolicy: ImmutableCandidateConflictPolicy
    ) throws -> KEMIdentityKeyRecord {
        try validateKEMRecord(
            record,
            suiteWireId: record.suiteWireId,
            tier: tier
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(record)
        
        let account = kemAccount(suiteWireId: record.suiteWireId, tier: tier)
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.kemService + "|" + account
            let winnerData = Self.inMemoryKEMLock.withLock { () -> Data in
                if let existing = Self.inMemoryKEMStore[key] {
                    return existing
                }
                Self.inMemoryKEMStore[key] = data
                return data
            }
            let winner = try decodeKEMRecord(
                winnerData,
                suiteWireId: record.suiteWireId,
                tier: tier
            )
            if conflictPolicy == .requireExactCandidate, winner != record {
                throw DeviceIdentityKeyError.authorityConflict(
                    "immutable Keychain winner differs for \(KeychainConstants.kemService)/\(account)"
                )
            }
            return winner
        }

        let winnerData = try insertImmutableGenericPasswordCandidate(
            service: KeychainConstants.kemService,
            account: account,
            data: data,
            conflictPolicy: conflictPolicy,
            validate: { encoded in
                _ = try self.decodeKEMRecord(
                    encoded,
                    suiteWireId: record.suiteWireId,
                    tier: tier
                )
            },
            equivalent: { lhs, rhs in
                try self.decodeKEMRecord(
                    lhs,
                    suiteWireId: record.suiteWireId,
                    tier: tier
                ) == self.decodeKEMRecord(
                    rhs,
                    suiteWireId: record.suiteWireId,
                    tier: tier
                )
            }
        )
        return try decodeKEMRecord(
            winnerData,
            suiteWireId: record.suiteWireId,
            tier: tier
        )
    }

    private struct KEMCacheKey: Hashable, Sendable {
        let suiteWireId: UInt16
        let tier: CryptoTier
    }

    private func kemAccount(suiteWireId: UInt16, tier: CryptoTier?) -> String {
        if let tier {
            return KeychainConstants.kemKeyPrefix + "\(suiteWireId)-\(tier.rawValue)"
        }
        return KeychainConstants.kemKeyPrefix + String(suiteWireId)
    }

    private func loadKEMKeyRecord(
        account: String,
        suiteWireId: UInt16,
        tier: CryptoTier
    ) throws -> KEMIdentityKeyRecord? {
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.kemService + "|" + account
            Self.inMemoryKEMLock.lock()
            let data = Self.inMemoryKEMStore[key]
            Self.inMemoryKEMLock.unlock()
            guard let data else { return nil }
            return try decodeKEMRecord(
                data,
                suiteWireId: suiteWireId,
                tier: tier
            )
        }
        guard let data = try readGenericPasswordData(
            service: KeychainConstants.kemService,
            account: account,
            validate: { encoded in
                _ = try self.decodeKEMRecord(
                    encoded,
                    suiteWireId: suiteWireId,
                    tier: tier
                )
            },
            equivalent: { lhs, rhs in
                try self.decodeKEMRecord(
                    lhs,
                    suiteWireId: suiteWireId,
                    tier: tier
                ) == self.decodeKEMRecord(
                    rhs,
                    suiteWireId: suiteWireId,
                    tier: tier
                )
            }
        ) else {
            return nil
        }

        return try decodeKEMRecord(
            data,
            suiteWireId: suiteWireId,
            tier: tier
        )
    }

    private func decodeKEMRecord(
        _ data: Data,
        suiteWireId: UInt16,
        tier: CryptoTier
    ) throws -> KEMIdentityKeyRecord {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let record = try decoder.decode(KEMIdentityKeyRecord.self, from: data)
        try validateKEMRecord(record, suiteWireId: suiteWireId, tier: tier)
        return record
    }

    private func kemRecordMatchesProvider(
        _ record: KEMIdentityKeyRecord,
        suiteWireId: UInt16,
        tier: CryptoTier
    ) -> Bool {
        guard record.suiteWireId == suiteWireId,
              suiteWireId != CryptoSuite.qperiaptContextBound.wireId else {
            return false
        }
        guard let contract = KEMIdentityKeyLengthContract.resolve(
            suite: CryptoSuite(wireId: suiteWireId),
            providerTier: tier
        ) else {
            return false
        }
        return record.privateKey.count == contract.privateKeyLength
            && record.publicKey.count == contract.publicKeyLength
    }

    private func validateKEMRecord(
        _ record: KEMIdentityKeyRecord,
        suiteWireId: UInt16,
        tier: CryptoTier
    ) throws {
        guard record.suiteWireId == suiteWireId else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "stored KEM suite does not match its identity slot"
            )
        }
        guard let contract = KEMIdentityKeyLengthContract.resolve(
            suite: CryptoSuite(wireId: suiteWireId),
            providerTier: tier
        ) else {
            throw CryptoProviderError.unsupportedAlgorithm(
                "No KEM identity length contract for suite \(suiteWireId) and tier \(tier.rawValue)"
            )
        }
        guard record.publicKey.count == contract.publicKeyLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: contract.publicKeyLength,
                actual: record.publicKey.count,
                suite: CryptoSuite(wireId: suiteWireId).rawValue,
                usage: .keyExchange
            )
        }
        guard record.privateKey.count == contract.privateKeyLength else {
            throw CryptoProviderError.invalidKeyLength(
                expected: contract.privateKeyLength,
                actual: record.privateKey.count,
                suite: CryptoSuite(wireId: suiteWireId).rawValue,
                usage: .keyExchange
            )
        }
    }
    
 /// 计算公钥指纹
    private func computePublicKeyFingerprint(_ publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    private func loadStoredDeviceIdStrict() throws -> String? {
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + KeychainConstants.deviceIdKey
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            guard let data else { return nil }
            guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
                throw DeviceIdentityKeyError.invalidKeyData
            }
            saveMirroredDeviceId(value)
            return value
        }
        throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
            "deviceId must be loaded from the identity authority"
        )
    }

    private func saveDeviceIdStrict(_ deviceId: String) throws {
        guard let data = deviceId.data(using: .utf8) else {
            throw DeviceIdentityKeyError.invalidKeyData
        }

        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + KeychainConstants.deviceIdKey
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            saveMirroredDeviceId(deviceId)
            return
        }

        throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
            "deviceId cannot be persisted independently of the identity authority"
        )
    }

    private func saveMirroredDeviceId(_ deviceId: String) {
        UserDefaults.standard.set(deviceId, forKey: KeychainConstants.mirroredDeviceIdDefaultsKey)
    }

    private func saveMirroredData(_ data: Data, forKey key: String) {
        UserDefaults.standard.set(data, forKey: key)
    }

    private func readGenericPasswordData(
        service: String,
        account: String,
        includeLegacyMigration: Bool = true,
        validate: (Data) throws -> Void,
        equivalent: (Data, Data) throws -> Bool = { $0 == $1 }
    ) throws -> Data? {
        let migrationScope = try resolvedSharedIdentityKeychainScope()
        let authoritativeScope = try migrationScope.authoritativeOnly()
        if let authoritative = try KeychainManager.shared.exportKeyStrict(
            service: service,
            account: account,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) {
            try validate(authoritative)
            if includeLegacyMigration {
                try reconcileLegacyGenericPasswordCandidates(
                    service: service,
                    account: account,
                    authoritative: authoritative,
                    authoritativeScope: authoritativeScope,
                    validate: validate,
                    equivalent: equivalent
                )
            }
            return authoritative
        }

        guard includeLegacyMigration else {
            return nil
        }
        var legacyCandidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
            service: service,
            account: account,
            includeLegacyKeychain: true
        )
        defer {
            for index in legacyCandidates.indices {
                legacyCandidates[index].data.secureErase()
            }
        }
        if let concurrentAuthority = try KeychainManager.shared.exportKeyStrict(
            service: service,
            account: account,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) {
            try validate(concurrentAuthority)
            try reconcileLegacyGenericPasswordCandidates(
                service: service,
                account: account,
                authoritative: concurrentAuthority,
                authoritativeScope: authoritativeScope,
                validate: validate,
                equivalent: equivalent
            )
            return concurrentAuthority
        }
        guard let legacy = legacyCandidates.first?.data else { return nil }
        for candidate in legacyCandidates {
            try validate(candidate.data)
            guard try equivalent(candidate.data, legacy) else {
                throw DeviceIdentityAuthorityError
                    .immutableGenericPasswordConflict(
                        service: service,
                        account: account
                    )
            }
        }
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: legacy,
            service: service,
            account: account,
            scope: authoritativeScope
        )
        guard let winner = try KeychainManager.shared.exportKeyStrict(
            service: service,
            account: account,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "immutable Keychain winner is missing for \(service)/\(account)"
            )
        }
        try validate(winner)
        guard try equivalent(winner, legacy) else {
            throw DeviceIdentityAuthorityError
                .immutableGenericPasswordConflict(
                    service: service,
                    account: account
                )
        }
        try reconcileLegacyGenericPasswordCandidates(
            service: service,
            account: account,
            authoritative: winner,
            authoritativeScope: authoritativeScope,
            validate: validate,
            equivalent: equivalent
        )
        return winner
    }

    private func reconcileLegacyGenericPasswordCandidates(
        service: String,
        account: String,
        authoritative: Data,
        authoritativeScope: KeychainGenericPasswordScope,
        validate: (Data) throws -> Void,
        equivalent: (Data, Data) throws -> Bool
    ) throws {
        guard let authoritativeAccessGroup = authoritativeScope.writeAccessGroup else {
            throw KeychainGenericPasswordScopeError.missingAuthoritativeWriteAccessGroup
        }
        var candidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: service,
                account: account,
                includeLegacyKeychain: true
            )
        defer {
            for index in candidates.indices {
                candidates[index].data.secureErase()
            }
        }
        for candidate in candidates {
            try validate(candidate.data)
            let isAuthoritative = candidate.location.actualAccessGroup
                    == authoritativeAccessGroup
                && candidate.location.usesDataProtectionKeychain
                    == authoritativeScope.usesDataProtectionKeychain
            guard try equivalent(candidate.data, authoritative) else {
                throw DeviceIdentityAuthorityError
                    .immutableGenericPasswordConflict(
                        service: service,
                        account: account
                    )
            }
            if !isAuthoritative {
                try KeychainManager.shared
                    .deleteLegacyGenericPasswordCandidate(candidate)
            }
        }
    }

    private func insertImmutableGenericPasswordCandidate(
        service: String,
        account: String,
        data: Data,
        conflictPolicy: ImmutableCandidateConflictPolicy,
        validate: (Data) throws -> Void,
        equivalent: (Data, Data) throws -> Bool = { $0 == $1 }
    ) throws -> Data {
        try validate(data)
        let authoritativeScope = try resolvedSharedIdentityKeychainScope()
            .authoritativeOnly()
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: data,
            service: service,
            account: account,
            scope: authoritativeScope
        )
        guard let winner = try KeychainManager.shared.exportKeyStrict(
            service: service,
            account: account,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "immutable Keychain winner is missing for \(service)/\(account)"
            )
        }
        try validate(winner)
        if conflictPolicy == .requireExactCandidate,
           !(try equivalent(winner, data)) {
            throw DeviceIdentityAuthorityError
                .immutableGenericPasswordConflict(
                    service: service,
                    account: account
                )
        }
        try reconcileLegacyGenericPasswordCandidates(
            service: service,
            account: account,
            authoritative: winner,
            authoritativeScope: authoritativeScope,
            validate: validate,
            equivalent: equivalent
        )
        return winner
    }
    
 // MARK: - Ed25519 Protocol Signing Key Helpers ( 5.1)
    
 /// 创建 Ed25519 协议签名密钥
    private func createProtocolSigningKey() throws -> (publicKey: Data, privateKey: Data) {
        let candidatePrivateKey = Curve25519.Signing.PrivateKey()
        var candidatePrivateKeyData = candidatePrivateKey.rawRepresentation
        defer { candidatePrivateKeyData.secureErase() }
        
 // 存储到 Keychain
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + KeychainConstants.protocolSigningKeyTag
            let privateKeyData = Self.inMemoryLock.withLock { () -> Data in
                if let winner = Self.inMemoryStore[key] {
                    return winner
                }
                Self.inMemoryStore[key] = candidatePrivateKeyData
                return candidatePrivateKeyData
            }
            let privateKey = try Curve25519.Signing.PrivateKey(
                rawRepresentation: privateKeyData
            )
            let publicKeyData = privateKey.publicKey.rawRepresentation
            saveMirroredData(publicKeyData, forKey: KeychainConstants.mirroredProtocolSigningPublicKeyDefaultsKey)
            SkyBridgeLogger.p2p.info("Created new Ed25519 protocol signing key (in-memory)")
            return (publicKey: publicKeyData, privateKey: privateKeyData)
        }

        let privateKeyData = try insertImmutableGenericPasswordCandidate(
            service: KeychainConstants.service,
            account: KeychainConstants.protocolSigningKeyTag,
            data: candidatePrivateKeyData,
            conflictPolicy: .adoptWinner,
            validate: { encoded in
                _ = try Curve25519.Signing.PrivateKey(rawRepresentation: encoded)
            }
        )
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: privateKeyData
        )
        let publicKeyData = privateKey.publicKey.rawRepresentation
        saveMirroredData(publicKeyData, forKey: KeychainConstants.mirroredProtocolSigningPublicKeyDefaultsKey)
        
        SkyBridgeLogger.p2p.info("Created new Ed25519 protocol signing key")
        return (publicKey: publicKeyData, privateKey: privateKeyData)
    }
    
 /// 加载 Ed25519 协议签名密钥
    private func loadProtocolSigningKey() throws -> (publicKey: Data, privateKey: Data)? {
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.service + "|" + KeychainConstants.protocolSigningKeyTag
            Self.inMemoryLock.lock()
            let privateKeyData = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            guard let privateKeyData else { return nil }
            let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
            return (publicKey: privateKey.publicKey.rawRepresentation, privateKey: privateKeyData)
        }

        guard let privateKeyData = try readGenericPasswordData(
            service: KeychainConstants.service,
            account: KeychainConstants.protocolSigningKeyTag,
            validate: { encoded in
                _ = try Curve25519.Signing.PrivateKey(rawRepresentation: encoded)
            }
        ) else {
            return nil
        }
        
 // 从私钥派生公钥
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let publicKeyData = privateKey.publicKey.rawRepresentation
        saveMirroredData(publicKeyData, forKey: KeychainConstants.mirroredProtocolSigningPublicKeyDefaultsKey)
        
        return (publicKey: publicKeyData, privateKey: privateKeyData)
    }
    
 // MARK: - ML-DSA protocol identity protection

    private func getOrCreateMLDSA87SigningIdentity() async throws -> (
        publicKey: Data,
        keyHandle: SigningKeyHandle
    ) {
        if let cachedMLDSA87SigningIdentity {
            return cachedMLDSA87SigningIdentity
        }
        let resolved = try await OQSProtocolMLDSASigningCallback.resolve(
            algorithm: .mlDSA87,
            identity: mldsa87StoreIdentity,
            scopeSource: effectiveSharedIdentityScopeSource
        )
        cachedMLDSA87SigningIdentity = resolved
        return resolved
    }

    /// Returns the authoritative protection mode already persisted for an
    /// algorithm. This is status, not user intent; absence means no identity
    /// has been provisioned for that algorithm yet.
    public func existingProtocolSigningKeyProtection(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> ProtocolSigningKeyProtection? {
        if try loadSecureEnclaveMLDSARecord(for: algorithm) != nil {
            return .secureEnclaveRequired
        }
        switch algorithm {
        case .ed25519:
            return try loadProtocolSigningKey() == nil ? nil : .softwareKeychain
        case .mlDSA65:
            return try loadMLDSASigningKey() == nil ? nil : .softwareKeychain
        case .mlDSA87:
            if cachedMLDSA87SigningIdentity != nil {
                return .softwareKeychain
            }
            let publicKey = try OQSBridge.existingSigningPublicKey(
                peerId: mldsa87StoreIdentity,
                algorithm: .mldsa87,
                authority: .active,
                scopeSource: effectiveSharedIdentityScopeSource
            )
            return publicKey == nil ? nil : .softwareKeychain
        }
    }

    private func getOrCreateSecureEnclaveMLDSAIdentity(
        for algorithm: ProtocolSigningAlgorithm
    ) async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
        guard algorithm != .ed25519 else {
            throw SecureEnclaveMLDSAIdentityError.unsupportedAlgorithm(algorithm)
        }
        if let cached = cachedSecureEnclaveMLDSAIdentities[algorithm] {
            return (cached.publicKey, .callback(cached.signingCallback))
        }
        if let existing = try loadSecureEnclaveMLDSARecord(for: algorithm) {
            let material = try await restoreSecureEnclaveMLDSARecord(existing)
            cachedSecureEnclaveMLDSAIdentities[algorithm] = material
            return (material.publicKey, .callback(material.signingCallback))
        }

        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw SecureEnclaveMLDSAIdentityError.sdkUnavailable
        }
        let candidate = try await SecureEnclaveMLDSAIdentityFactory.create(
            algorithm: algorithm
        )
        var candidateRecord = SecureEnclaveMLDSAIdentityRecord(
            algorithm: algorithm,
            publicKey: candidate.publicKey,
            opaqueKeyRepresentation: candidate.opaqueKeyRepresentation
        )
        defer { candidateRecord.wipeOpaqueKeyRepresentation() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encoded = try encoder.encode(candidateRecord)
        defer { encoded.secureErase() }
        guard encoded.count <= SecureEnclaveMLDSAIdentityRecord.maximumEncodedSize else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Secure Enclave protocol identity record exceeds its size bound"
            )
        }

        let scope = try resolvedSharedIdentityKeychainScope().authoritativeOnly()
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: encoded,
            service: secureEnclaveMLDSAService,
            account: secureEnclaveMLDSAAccount(for: algorithm),
            scope: scope
        )
        guard let winner = try loadSecureEnclaveMLDSARecord(for: algorithm) else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Secure Enclave protocol identity winner is missing after compare-and-set"
            )
        }
        let material = try await restoreSecureEnclaveMLDSARecord(winner)
        cachedSecureEnclaveMLDSAIdentities[algorithm] = material
        return (material.publicKey, .callback(material.signingCallback))
    }

    private func loadSecureEnclaveMLDSARecord(
        for algorithm: ProtocolSigningAlgorithm
    ) throws -> SecureEnclaveMLDSAIdentityRecord? {
        let scope = try resolvedSharedIdentityKeychainScope().authoritativeOnly()
        let account = secureEnclaveMLDSAAccount(for: algorithm)
        if let preferred = try loadSecureEnclaveMLDSARecord(
            for: algorithm,
            account: account,
            scope: scope
        ) {
            return preferred
        }

        // Pre-release builds used only the algorithm as the account. Copy that
        // immutable record into the versioned `(algorithm, protection)` slot;
        // the old item is intentionally retained for rollback/read compatibility.
        guard let legacy = try loadSecureEnclaveMLDSARecord(
            for: algorithm,
            account: algorithm.rawValue,
            scope: scope
        ) else {
            return nil
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var encoded = try encoder.encode(legacy)
        defer { encoded.secureErase() }
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: encoded,
            service: secureEnclaveMLDSAService,
            account: account,
            scope: scope
        )
        guard let winner = try loadSecureEnclaveMLDSARecord(
            for: algorithm,
            account: account,
            scope: scope
        ), winner == legacy else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Secure Enclave protocol identity migration produced a conflicting winner"
            )
        }
        return winner
    }

    private func secureEnclaveMLDSAAccount(
        for algorithm: ProtocolSigningAlgorithm
    ) -> String {
        "protocol-signing|\(algorithm.rawValue)|\(ProtocolSigningKeyProtection.secureEnclaveRequired.rawValue)|v1"
    }

    private func loadSecureEnclaveMLDSARecord(
        for algorithm: ProtocolSigningAlgorithm,
        account: String,
        scope: KeychainGenericPasswordScope
    ) throws -> SecureEnclaveMLDSAIdentityRecord? {
        guard var encoded = try KeychainManager.shared.exportKeyStrict(
            service: secureEnclaveMLDSAService,
            account: account,
            scope: scope,
            includeLegacyKeychain: false
        ) else {
            return nil
        }
        defer { encoded.secureErase() }
        guard encoded.count <= SecureEnclaveMLDSAIdentityRecord.maximumEncodedSize else {
            throw DeviceIdentityKeyError.corruptIdentityAuthority(
                "Secure Enclave protocol identity record exceeds its size bound"
            )
        }
        return try JSONDecoder().decode(
            SecureEnclaveMLDSAIdentityRecord.self,
            from: encoded
        ).validated(for: algorithm)
    }

    private func restoreSecureEnclaveMLDSARecord(
        _ record: SecureEnclaveMLDSAIdentityRecord
    ) async throws -> SecureEnclaveMLDSAIdentityMaterial {
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw SecureEnclaveMLDSAIdentityError.sdkUnavailable
        }
        return try await SecureEnclaveMLDSAIdentityFactory.restore(
            algorithm: record.algorithm,
            publicKey: record.publicKey,
            opaqueKeyRepresentation: record.opaqueKeyRepresentation
        )
    }

 // MARK: - ML-DSA-65 Protocol Signing Key Helpers ( 11.2, 11.3)
    
 /// 获取或创建 ML-DSA-65 协议签名密钥。
 ///
 /// v3 uses one add-only Keychain item as the sole authority. Legacy split
 /// public/private items are accepted only as a complete, cryptographically
 /// matched migration input.
    public func getOrCreateMLDSASigningKey() async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
        if let cached = cachedMLDSASigningKey {
            return (publicKey: cached.publicKey, keyHandle: .softwareKey(cached.privateKey))
        }

        do {
            let record = try PQCKeyPairStore.loadOrCreate(
                descriptor: mldsaStoreDescriptor,
                publicKeyLength: KeychainConstants.mldsaPublicKeyLength,
                privateKeyLength: KeychainConstants.mldsaPrivateKeyLength,
                legacyKeyPair: mldsaLegacyKeyPair,
                validatePair: validateMLDSARecord,
                generate: generateMLDSARecord
            )
            let resolved = (publicKey: record.publicKey, privateKey: record.privateKey)
            saveMirroredData(resolved.publicKey, forKey: mldsaMirrorDefaultsKey)
            cachedMLDSASigningKey = resolved
            SkyBridgeLogger.p2p.info("Resolved canonical ML-DSA-65 protocol signing key")
            return (
                publicKey: resolved.publicKey,
                keyHandle: .softwareKey(resolved.privateKey)
            )
        } catch {
            throw translateMLDSAStorageError(error)
        }
    }

    private func generateMLDSARecord() throws -> PQCKeyPairRecord {
        #if canImport(OQSRAII)
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        guard pkLen == KeychainConstants.mldsaPublicKeyLength,
              skLen == KeychainConstants.mldsaPrivateKeyLength,
              oqs_raii_mldsa65_signature_length() == KeychainConstants.mldsaSignatureLength else {
            throw DeviceIdentityKeyError.keyGenerationFailed(
                "ML-DSA-65 runtime length contract mismatch"
            )
        }

        var publicKeyBytes = [UInt8](repeating: 0, count: Int(pkLen))
        var privateKeyBytes = [UInt8](repeating: 0, count: Int(skLen))
        defer {
            PQCKeyPairRecordCodec.wipe(&publicKeyBytes)
            PQCKeyPairRecordCodec.wipe(&privateKeyBytes)
        }

        let result = oqs_raii_mldsa65_keypair(
            &publicKeyBytes, pkLen,
            &privateKeyBytes, skLen
        )

        guard result == OQSRAII_SUCCESS else {
            throw DeviceIdentityKeyError.keyGenerationFailed("ML-DSA-65 keypair generation failed")
        }
        return PQCKeyPairRecord(
            algorithmIdentifier: mldsaStoreDescriptor.algorithmIdentifier,
            publicKey: Data(publicKeyBytes),
            privateKey: Data(privateKeyBytes)
        )
        #else
        throw DeviceIdentityKeyError.keyGenerationFailed("OQSRAII not available")
        #endif
    }

    private func loadMLDSASigningKey() throws -> (publicKey: Data, privateKey: Data)? {
        do {
            guard let record = try PQCKeyPairStore.loadOrMigrateLegacy(
                descriptor: mldsaStoreDescriptor,
                publicKeyLength: KeychainConstants.mldsaPublicKeyLength,
                privateKeyLength: KeychainConstants.mldsaPrivateKeyLength,
                legacyKeyPair: mldsaLegacyKeyPair,
                validatePair: validateMLDSARecord
            ) else {
                return nil
            }
            saveMirroredData(record.publicKey, forKey: mldsaMirrorDefaultsKey)
            return (publicKey: record.publicKey, privateKey: record.privateKey)
        } catch {
            throw translateMLDSAStorageError(error)
        }
    }

    private func validateMLDSARecord(_ record: PQCKeyPairRecord) throws {
        try validateMLDSAKeyPair(
            publicKey: record.publicKey,
            privateKey: record.privateKey
        )
    }

    private func translateMLDSAStorageError(_ error: Error) -> Error {
        if let keychainError = error as? KeychainError {
            switch keychainError {
            case .itemNotFound:
                return DeviceIdentityKeyError.keyNotFound
            case .unexpectedError(let status):
                return DeviceIdentityKeyError.keychainError(status)
            case .decodingError:
                return DeviceIdentityKeyError.incompleteKeyMaterial(
                    "ML-DSA-65 canonical Keychain item could not be decoded"
                )
            case .itemChangedDuringReconciliation:
                return keychainError
            }
        }
        if error is PQCKeyPairRecordCodecError {
            return DeviceIdentityKeyError.incompleteKeyMaterial(
                "ML-DSA-65 canonical record failed strict decoding"
            )
        }
        if let storeError = error as? PQCKeyPairStoreError {
            switch storeError {
            case .incompleteLegacyKeyPair:
                return DeviceIdentityKeyError.incompleteKeyMaterial(
                    "ML-DSA-65 public/private keypair is incomplete (legacy split record)"
                )
            case .conflictingLegacyKeyPair:
                return DeviceIdentityKeyError.authorityConflict(
                    "Conflicting ML-DSA-65 canonical and legacy key material"
                )
            case .canonicalRecordMissingAfterInsert:
                return DeviceIdentityKeyError.incompleteKeyMaterial(
                    "ML-DSA-65 canonical record disappeared after atomic insertion"
                )
            default:
                return storeError
            }
        }
        return error
    }

    private func validateMLDSAKeyPair(publicKey: Data, privateKey: Data) throws {
        #if canImport(OQSRAII)
        guard publicKey.count == KeychainConstants.mldsaPublicKeyLength,
              privateKey.count == KeychainConstants.mldsaPrivateKeyLength,
              oqs_raii_mldsa65_public_key_length() == KeychainConstants.mldsaPublicKeyLength,
              oqs_raii_mldsa65_secret_key_length() == KeychainConstants.mldsaPrivateKeyLength,
              oqs_raii_mldsa65_signature_length() == KeychainConstants.mldsaSignatureLength else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "ML-DSA-65 keypair violates the fixed-length contract"
            )
        }

        let challenge = Array("SkyBridge ML-DSA-65 canonical keypair validation v3".utf8)
        var signature = [UInt8](
            repeating: 0,
            count: KeychainConstants.mldsaSignatureLength
        )
        defer {
            PQCKeyPairRecordCodec.wipe(&signature)
        }
        var signatureLength = signature.count

        let signResult = challenge.withUnsafeBufferPointer { message in
            privateKey.withUnsafeBytes { secretKey in
                oqs_raii_mldsa65_sign(
                    message.baseAddress,
                    message.count,
                    secretKey.bindMemory(to: UInt8.self).baseAddress,
                    privateKey.count,
                    &signature,
                    &signatureLength
                )
            }
        }
        guard signResult == OQSRAII_SUCCESS,
              signatureLength == KeychainConstants.mldsaSignatureLength else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "ML-DSA-65 private key failed the validation challenge"
            )
        }

        let verified = challenge.withUnsafeBufferPointer { message in
            publicKey.withUnsafeBytes { publicKeyBytes in
                signature.withUnsafeBufferPointer { signatureBytes in
                    oqs_raii_mldsa65_verify(
                        message.baseAddress,
                        message.count,
                        signatureBytes.baseAddress,
                        signatureLength,
                        publicKeyBytes.bindMemory(to: UInt8.self).baseAddress,
                        publicKey.count
                    )
                }
            }
        }
        guard verified else {
            throw DeviceIdentityKeyError.incompleteKeyMaterial(
                "ML-DSA-65 public/private keys failed pair validation"
            )
        }
        #else
        throw DeviceIdentityKeyError.keyGenerationFailed("OQSRAII not available")
        #endif
    }

    #if DEBUG || SKYBRIDGE_TESTING
    private nonisolated static func testingMLDSAService(namespace: String) -> String {
        KeychainConstants.mldsaService + ".testing." + namespace
    }

    private nonisolated static func testingMLDSAMirrorDefaultsKey(namespace: String) -> String {
        KeychainConstants.mirroredMLDSAPublicKeyDefaultsKey + ".testing." + namespace
    }

    private nonisolated static func testingMLDSAKeychainScope(
        namespace: String
    ) -> KeychainGenericPasswordScope {
        let accessGroup = "group.com.skybridge.tests.device-identity.\(namespace)"
        return KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup, nil],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
    }

    private nonisolated static func testingMLDSALocation(
        namespace: String,
        account: String
    ) -> KeychainGenericPasswordLocation {
        KeychainGenericPasswordLocation(
            service: testingMLDSAService(namespace: namespace),
            account: account
        )
    }

    private nonisolated static func testingSetMLDSAStorageData(
        _ data: Data?,
        location: KeychainGenericPasswordLocation,
        namespace: String
    ) throws {
        let keychainScope = testingMLDSAKeychainScope(namespace: namespace)
        try KeychainManager.shared.deleteAPIKey(
            service: location.service,
            account: location.account,
            scope: keychainScope
        )
        if let data {
            _ = try KeychainManager.shared.insertKeyIfAbsent(
                data: data,
                service: location.service,
                account: location.account,
                scope: keychainScope
            )
        }
    }

    internal nonisolated static func testingResetMLDSAStorage(namespace: String) throws {
        let service = testingMLDSAService(namespace: namespace)
        let keychainScope = testingMLDSAKeychainScope(namespace: namespace)
        for account in [
            KeychainConstants.mldsaCanonicalKeyPairAccount,
            KeychainConstants.mldsaPublicKeyAccount,
            KeychainConstants.mldsaSecretKeyAccount
        ] {
            try KeychainManager.shared.deleteAPIKey(
                service: service,
                account: account,
                scope: keychainScope
            )
        }
        try PQCBackendAuthorityStore.deleteForTesting(
            domain: .testing("device-protocol-signing.\(namespace)"),
            scopeSource: .explicitForTesting(keychainScope)
        )
        UserDefaults.standard.removeObject(
            forKey: testingMLDSAMirrorDefaultsKey(namespace: namespace)
        )
    }

    internal nonisolated static func testingSeedLegacyMLDSAStorage(
        namespace: String,
        publicKey: Data?,
        privateKey: Data?
    ) throws {
        try testingSetMLDSAStorageData(
            publicKey,
            location: testingMLDSALocation(
                namespace: namespace,
                account: KeychainConstants.mldsaPublicKeyAccount
            ),
            namespace: namespace
        )
        try testingSetMLDSAStorageData(
            privateKey,
            location: testingMLDSALocation(
                namespace: namespace,
                account: KeychainConstants.mldsaSecretKeyAccount
            ),
            namespace: namespace
        )
    }

    internal nonisolated static func testingSeedCanonicalMLDSAStorage(
        namespace: String,
        encodedRecord: Data
    ) throws {
        try testingSetMLDSAStorageData(
            encodedRecord,
            location: testingMLDSALocation(
                namespace: namespace,
                account: KeychainConstants.mldsaCanonicalKeyPairAccount
            ),
            namespace: namespace
        )
    }

    internal nonisolated static func testingHasCanonicalMLDSARecord(
        namespace: String
    ) throws -> Bool {
        let keychainScope = testingMLDSAKeychainScope(namespace: namespace)
        let location = testingMLDSALocation(
            namespace: namespace,
            account: KeychainConstants.mldsaCanonicalKeyPairAccount
        )
        return try KeychainManager.shared.exportKeyStrict(
            service: location.service,
            account: location.account,
            scope: keychainScope,
            includeLegacyKeychain: true
        ) != nil
    }

    internal nonisolated static func testingSetMirroredMLDSAPublicKey(
        _ publicKey: Data?,
        namespace: String
    ) {
        let key = testingMLDSAMirrorDefaultsKey(namespace: namespace)
        if let publicKey {
            UserDefaults.standard.set(publicKey, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    internal nonisolated static func testingMirroredMLDSAPublicKey(
        namespace: String
    ) -> Data? {
        UserDefaults.standard.data(
            forKey: testingMLDSAMirrorDefaultsKey(namespace: namespace)
        )
    }
    #endif

 // MARK: - SE PoP Key Helpers ( 5.2)
    
 /// 获取 SE PoP 密钥引用
    private func getSEPoPKeyReference() throws -> SecKey? {
        if Self.useInMemoryKeychain { return nil }
        do {
            let store = try identityAuthorityStore()
            guard let authority = try DeviceIdentityAuthorityTransaction.resolve(
                using: store
            ), authority.isSecureEnclave else {
                return nil
            }
            return try store.loadAuthoritativePrivateKey(
                applicationTag: authority.privateKeyApplicationTag
            )
        } catch {
            throw Self.publicIdentityError(for: error)
        }
    }
}

// MARK: - KeyPurpose

/// 密钥用途枚举
///
/// **Requirements: 5.4**
public enum KeyPurpose: String, Sendable {
 /// 旧 P-256 身份密钥（迁移前）
    case legacy = "legacy"

    /// 当前 immutable authority 引用的 unique-tag P-256 身份密钥
    case identity = "identity"
    
 /// Ed25519/ML-DSA 协议签名密钥
    case `protocol` = "protocol"
    
 /// P-256 SE PoP 密钥（迁移后）
    case pop = "pop"
    
 /// 未知用途
    case unknown = "unknown"
}
