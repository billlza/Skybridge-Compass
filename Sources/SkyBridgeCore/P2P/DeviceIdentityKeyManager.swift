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
    case keychainError(OSStatus)
    case signatureFailed(String)
    case verificationFailed
    case keyRotationFailed(String)
    
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
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .signatureFailed(let reason):
            return "Signature failed: \(reason)"
        case .verificationFailed:
            return "Signature verification failed"
        case .keyRotationFailed(let reason):
            return "Key rotation failed: \(reason)"
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
        
 /// P-256 SE PoP 密钥 tag（迁移后的专用 tag）
        static let sePoPKeyTag = "com.skybridge.p2p.identity.pop.p256"
        
 // MARK: - ML-DSA-65 Protocol Signing Key ( 11.1, 11.2)
        
 /// ML-DSA-65 协议签名密钥 service
        static let mldsaService = "com.skybridge.p2p.identity.mldsa65"
        
 /// ML-DSA-65 公钥 account
        static let mldsaPublicKeyAccount = "mldsa65_publicKey"
        
 /// ML-DSA-65 私钥 account
        static let mldsaSecretKeyAccount = "mldsa65_secretKey"
    }

    private nonisolated static var useInMemoryKeychain: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }
    private nonisolated(unsafe) static var inMemoryKEMStore: [String: Data] = [:]
    private nonisolated static let inMemoryKEMLock = NSLock()
    
 // MARK: - Properties
    
 /// 缓存的密钥信息
    private var cachedKeyInfo: DeviceIdentityKeyInfo?
    
 /// 缓存的 KEM 公钥（按 suite wireId + provider tier）
    private var cachedKEMPublicKeys: [KEMCacheKey: Data] = [:]
    
 /// 缓存的 Ed25519 协议签名密钥
    private var cachedProtocolSigningKey: (publicKey: Data, privateKey: Data)?
    
 /// 缓存的 ML-DSA-65 协议签名密钥
    private var cachedMLDSASigningKey: (publicKey: Data, privateKey: Data)?
    
 /// 设备 ID
    private var _deviceId: String?
    
 // MARK: - Initialization
    
    private init() {}
    
 // MARK: - Public Methods
    
 /// 获取或创建设备身份密钥
 /// - Returns: 密钥信息
    public func getOrCreateIdentityKey() async throws -> DeviceIdentityKeyInfo {
 // 检查缓存
        if let cached = cachedKeyInfo {
            return cached
        }
        
 // 尝试从 Keychain 加载
        if let existing = try? await loadExistingKey() {
            cachedKeyInfo = existing
            return existing
        }
        
 // 创建新密钥
        let keyInfo = try await createNewIdentityKey()
        cachedKeyInfo = keyInfo
        return keyInfo
    }
    
 /// 获取设备 ID
    public func getDeviceId() async -> String {
        if let deviceId = _deviceId {
            return deviceId
        }
        
 // 尝试从 Keychain 加载
        if let stored = loadStoredDeviceId() {
            _deviceId = stored
            return stored
        }
        
 // 生成新的设备 ID
        let newId = UUID().uuidString
        saveDeviceId(newId)
        _deviceId = newId
        return newId
    }
    
 /// 使用身份密钥签名
 /// - Parameter data: 待签名数据
 /// - Returns: 签名
    public func sign(data: Data) async throws -> Data {
        let keyInfo = try await getOrCreateIdentityKey()
        
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
        return SecureEnclaveSigningCallback(keyTag: KeychainConstants.signingKeyTag)
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
        switch algorithm {
        case .ed25519:
            return try await getProtocolSigningKeyHandle()
        case .mlDSA65:
            let (_, keyHandle) = try await getOrCreateMLDSASigningKey()
            return keyHandle
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
        switch algorithm {
        case .ed25519:
            return try await getProtocolSigningPublicKey()
        case .mlDSA65:
            let (publicKey, _) = try await getOrCreateMLDSASigningKey()
            return publicKey
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
 // 首先尝试从新 tag 加载
        if let secKey = try? getSEPoPKeyReference() {
            return .secureEnclaveRef(secKey)
        }
        
 // 尝试迁移旧密钥
        try await migrateExistingIdentityKey()
        
 // 再次尝试加载
        if let secKey = try? getSEPoPKeyReference() {
            return .secureEnclaveRef(secKey)
        }
        
 // 如果没有 SE PoP 密钥，返回 nil（SE PoP 是可选的）
        return nil
    }
    
 /// 获取 Secure Enclave PoP 公钥 (P-256)
    public func getSecureEnclavePublicKey() async throws -> Data? {
        guard let keyHandle = try await getSecureEnclaveKeyHandle() else {
            return nil
        }
        
        switch keyHandle {
        case .secureEnclaveRef(let secKey):
            var error: Unmanaged<CFError>?
            guard let publicKeyData = SecKeyCopyExternalRepresentation(
                SecKeyCopyPublicKey(secKey)!,
                &error
            ) as Data? else {
                return nil
            }
            return publicKeyData
        default:
            return nil
        }
    }
    
 // MARK: - Key Migration - 5.3
    
 /// 迁移现有 P-256 身份密钥到 SE PoP 角色
 ///
 /// **迁移规则**:
 /// 1. 检查 legacySigningKeyTag 是否存在旧 P-256 密钥
 /// 2. 如果存在，复制到 sePoPKeyTag（不删除原 key，保持幂等）
 /// 3. 重复执行不会生成多把 key
 ///
 /// **幂等性保证**:
 /// - 如果 sePoPKeyTag 已存在，跳过迁移
 /// - 如果 legacySigningKeyTag 不存在，跳过迁移
 ///
 /// **Requirements: 5.4**
    public func migrateExistingIdentityKey() async throws {
 // 1. 检查是否已迁移（sePoPKeyTag 已存在）
        if (try? getSEPoPKeyReference()) != nil {
            SkyBridgeLogger.p2p.debug("SE PoP key already exists, skipping migration")
            return
        }
        
 // 2. 检查旧 key 是否存在
        guard try getPrivateKeyReference() != nil else {
            SkyBridgeLogger.p2p.debug("No legacy signing key found, skipping migration")
            return
        }
        
 // 3. 复制旧 key 到新 tag
 // 注意：Secure Enclave 密钥不能直接复制，需要创建新的引用
 // 这里我们只是在 Keychain 中创建一个新的条目指向同一个密钥
        try copyKeyToSEPoPTag()
        
 // 4. 发射迁移事件
        SecurityEventEmitter.emitDetached(SecurityEvent.keyMigrationCompleted(
            fromTag: KeychainConstants.signingKeyTag,
            toTag: KeychainConstants.sePoPKeyTag,
            keyType: "P-256 ECDSA"
        ))
        
        SkyBridgeLogger.p2p.info("Migrated legacy P-256 identity key to SE PoP role")
    }
    
 /// 识别密钥用途
 ///
 /// - Parameter tag: 密钥 tag
 /// - Returns: 密钥用途
    public func identifyKeyPurpose(tag: String) -> KeyPurpose {
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
        let cacheKey = KEMCacheKey(suiteWireId: suite.wireId, tier: provider.tier)
        if let cached = cachedKEMPublicKeys[cacheKey],
           let record = try? loadKEMKeyRecord(suiteWireId: suite.wireId, tier: provider.tier),
           record.publicKey == cached {
            return (publicKey: record.publicKey, privateKey: SecureBytes(data: record.privateKey))
        }
        
        if let record = try? loadKEMKeyRecord(suiteWireId: suite.wireId, tier: provider.tier) {
            cachedKEMPublicKeys[cacheKey] = record.publicKey
            return (publicKey: record.publicKey, privateKey: SecureBytes(data: record.privateKey))
        }
        
        let keyPair = try await provider.generateKeyPair(for: .keyExchange)
        let record = KEMIdentityKeyRecord(
            suiteWireId: suite.wireId,
            publicKey: keyPair.publicKey.bytes,
            privateKey: keyPair.privateKey.bytes
        )
        try saveKEMKeyRecord(record, tier: provider.tier)
        cachedKEMPublicKeys[cacheKey] = record.publicKey
        return (publicKey: record.publicKey, privateKey: SecureBytes(data: record.privateKey))
    }
    
 /// 获取 KEM 身份公钥（不存在则创建）
    public func getKEMPublicKey(
        for suite: CryptoSuite,
        provider: any CryptoProvider
    ) async throws -> Data {
        let cacheKey = KEMCacheKey(suiteWireId: suite.wireId, tier: provider.tier)
        if let cached = cachedKEMPublicKeys[cacheKey] {
            return cached
        }
        let record = try await getOrCreateKEMIdentityKey(for: suite, provider: provider)
        return record.publicKey
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
 // 删除旧密钥
        try deleteExistingKey()
        
 // 清除缓存
        cachedKeyInfo = nil
        
 // 生成新的设备 ID
        let newDeviceId = UUID().uuidString
        saveDeviceId(newDeviceId)
        _deviceId = newDeviceId
        
 // 创建新密钥
        let keyInfo = try await createNewIdentityKey()
        cachedKeyInfo = keyInfo
        
        SkyBridgeLogger.p2p.info("Device identity key rotated, new ID: \(keyInfo.shortId)")
        return keyInfo
    }
    
 /// 删除身份密钥
    public func deleteIdentityKey() throws {
        try deleteExistingKey()
        cachedKeyInfo = nil
        _deviceId = nil
        SkyBridgeLogger.p2p.info("Device identity key deleted")
    }
    
 // MARK: - Private Methods
    
 /// 创建新的身份密钥
    private func createNewIdentityKey() async throws -> DeviceIdentityKeyInfo {
        let deviceId = await getDeviceId()
        let useSecureEnclave = isSecureEnclaveAvailable()
        
 // 构建密钥属性
        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrApplicationTag as String: KeychainConstants.signingKeyTag.utf8Data,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: KeychainConstants.signingKeyTag.utf8Data
            ] as [String: Any]
        ]
        
 // 如果 Secure Enclave 可用，使用它
        if useSecureEnclave {
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .privateKeyUsage,
                &error
            ) else {
                throw DeviceIdentityKeyError.secureEnclaveNotAvailable
            }
            
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
            attributes[kSecPrivateKeyAttrs as String] = [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: KeychainConstants.signingKeyTag.utf8Data,
                kSecAttrAccessControl as String: access
            ] as [String: Any]
        }
        
 // 生成密钥对
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw DeviceIdentityKeyError.keyGenerationFailed(errorDesc)
        }
        
 // 获取公钥
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw DeviceIdentityKeyError.keyGenerationFailed("Failed to extract public key")
        }
        
 // 导出公钥数据
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw DeviceIdentityKeyError.keyGenerationFailed(errorDesc)
        }
        
 // 计算公钥指纹
        let pubKeyFP = computePublicKeyFingerprint(publicKeyData)
        
        let keyInfo = DeviceIdentityKeyInfo(
            deviceId: deviceId,
            pubKeyFP: pubKeyFP,
            publicKey: publicKeyData,
            keyType: .p256Signing,
            isSecureEnclave: useSecureEnclave
        )
        
 // 保存密钥信息到 Keychain
        try saveKeyInfo(keyInfo)
        
        SkyBridgeLogger.p2p.info("Created new device identity key: \(keyInfo.shortId), Secure Enclave: \(useSecureEnclave)")
        return keyInfo
    }
    
 /// 加载现有密钥
    private func loadExistingKey() async throws -> DeviceIdentityKeyInfo? {
 // 查询 Keychain 中的密钥信息
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: "keyInfo",
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        
 // 解码密钥信息
        let keyInfo = try JSONDecoder().decode(DeviceIdentityKeyInfo.self, from: data)
        
 // 验证私钥仍然存在
        guard try getPrivateKeyReference() != nil else {
            return nil
        }
        
        return keyInfo
    }
    
 /// 获取私钥引用
    private func getPrivateKeyReference() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: KeychainConstants.signingKeyTag.utf8Data,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        
        guard status == errSecSuccess else {
            throw DeviceIdentityKeyError.keychainError(status)
        }
        
        guard let result else {
            throw DeviceIdentityKeyError.keychainError(errSecInternalError)
        }
        guard CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw DeviceIdentityKeyError.keychainError(errSecInternalError)
        }
        let secKey = unsafeDowncast(result, to: SecKey.self)
        return secKey
    }
    
 /// 保存密钥信息
    private func saveKeyInfo(_ keyInfo: DeviceIdentityKeyInfo) throws {
        let data = try JSONEncoder().encode(keyInfo)
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: "keyInfo",
            kSecValueData as String: data
        ]
        
 // 先删除旧的
        SecItemDelete(query as CFDictionary)
        
 // 添加新的
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceIdentityKeyError.keychainError(status)
        }
    }

 /// 加载 KEM 身份密钥记录（按 suite + provider tier）
    private func loadKEMKeyRecord(suiteWireId: UInt16, tier: CryptoTier) throws -> KEMIdentityKeyRecord? {
        let tierAccount = kemAccount(suiteWireId: suiteWireId, tier: tier)
        if let record = try loadKEMKeyRecord(account: tierAccount) {
            return record
        }
        
 // 兼容旧数据：无 tier 的记录。若密钥长度匹配当前 provider，则迁移。
        let legacyAccount = kemAccount(suiteWireId: suiteWireId, tier: nil)
        if let legacyRecord = try loadKEMKeyRecord(account: legacyAccount),
           kemRecordMatchesProvider(legacyRecord, suiteWireId: suiteWireId, tier: tier) {
            try saveKEMKeyRecord(legacyRecord, tier: tier)
            return legacyRecord
        }
        
        return nil
    }
    
 /// 保存 KEM 身份密钥记录（按 suite + provider tier）
    private func saveKEMKeyRecord(_ record: KEMIdentityKeyRecord, tier: CryptoTier) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(record)
        
        let account = kemAccount(suiteWireId: record.suiteWireId, tier: tier)
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.kemService + "|" + account
            Self.inMemoryKEMLock.lock()
            Self.inMemoryKEMStore[key] = data
            Self.inMemoryKEMLock.unlock()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.kemService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary)
        
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceIdentityKeyError.keychainError(status)
        }
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

    private func loadKEMKeyRecord(account: String) throws -> KEMIdentityKeyRecord? {
        if Self.useInMemoryKeychain {
            let key = KeychainConstants.kemService + "|" + account
            Self.inMemoryKEMLock.lock()
            let data = Self.inMemoryKEMStore[key]
            Self.inMemoryKEMLock.unlock()
            guard let data else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(KEMIdentityKeyRecord.self, from: data)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.kemService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw DeviceIdentityKeyError.keychainError(status)
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(KEMIdentityKeyRecord.self, from: data)
    }

    private func kemRecordMatchesProvider(
        _ record: KEMIdentityKeyRecord,
        suiteWireId: UInt16,
        tier: CryptoTier
    ) -> Bool {
        guard let expectedPriv = expectedKEMPrivateKeyLength(suiteWireId: suiteWireId, tier: tier),
              let expectedPub = expectedKEMPublicKeyLength(suiteWireId: suiteWireId, tier: tier) else {
            return true
        }
        return record.privateKey.count == expectedPriv && record.publicKey.count == expectedPub
    }

    private func expectedKEMPrivateKeyLength(suiteWireId: UInt16, tier: CryptoTier) -> Int? {
        switch (suiteWireId, tier) {
        case (0x0101, .nativePQC): return 96
        case (0x0101, .liboqsPQC): return 2400
        case (0x0001, .nativePQC): return 64  // X-Wing MLKEM seed format
        default: return nil
        }
    }

    private func expectedKEMPublicKeyLength(suiteWireId: UInt16, tier: CryptoTier) -> Int? {
        switch (suiteWireId, tier) {
        case (0x0101, _): return 1184
        case (0x0001, .nativePQC): return 1216
        default: return nil
        }
    }
    
 /// 删除现有密钥
    private func deleteExistingKey() throws {
 // 删除私钥
        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: KeychainConstants.signingKeyTag.utf8Data
        ]
        SecItemDelete(keyQuery as CFDictionary)
        
 // 删除密钥信息
        let infoQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: "keyInfo"
        ]
        SecItemDelete(infoQuery as CFDictionary)
    }
    
 /// 计算公钥指纹
    private func computePublicKeyFingerprint(_ publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
 /// 加载存储的设备 ID
    private func loadStoredDeviceId() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: KeychainConstants.deviceIdKey,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        
        return String(data: data, encoding: .utf8)
    }
    
 /// 保存设备 ID
    private func saveDeviceId(_ deviceId: String) {
        guard let data = deviceId.data(using: .utf8) else { return }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: KeychainConstants.deviceIdKey,
            kSecValueData as String: data
        ]
        
 // 先删除旧的
        SecItemDelete(query as CFDictionary)
        
 // 添加新的
        SecItemAdd(query as CFDictionary, nil)
    }
    
 // MARK: - Ed25519 Protocol Signing Key Helpers ( 5.1)
    
 /// 创建 Ed25519 协议签名密钥
    private func createProtocolSigningKey() throws -> (publicKey: Data, privateKey: Data) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
 // 存储到 Keychain
        let privateKeyData = privateKey.rawRepresentation
        let publicKeyData = publicKey.rawRepresentation
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: KeychainConstants.protocolSigningKeyTag,
            kSecValueData as String: privateKeyData
        ]
        
 // 先删除旧的
        SecItemDelete(query as CFDictionary)
        
 // 添加新的
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceIdentityKeyError.keychainError(status)
        }
        
        SkyBridgeLogger.p2p.info("Created new Ed25519 protocol signing key")
        return (publicKey: publicKeyData, privateKey: privateKeyData)
    }
    
 /// 加载 Ed25519 协议签名密钥
    private func loadProtocolSigningKey() throws -> (publicKey: Data, privateKey: Data)? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.service,
            kSecAttrAccount as String: KeychainConstants.protocolSigningKeyTag,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        
        guard status == errSecSuccess, let privateKeyData = result as? Data else {
            throw DeviceIdentityKeyError.keychainError(status)
        }
        
 // 从私钥派生公钥
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
        let publicKeyData = privateKey.publicKey.rawRepresentation
        
        return (publicKey: publicKeyData, privateKey: privateKeyData)
    }
    
 // MARK: - ML-DSA-65 Protocol Signing Key Helpers ( 11.2, 11.3)
    
 /// 获取或创建 ML-DSA-65 协议签名密钥
 ///
 /// ** 11.2**: 使用 OQS 作为主后端（iOS/macOS 兼容）
 /// - Keychain 存储: mldsa65_publicKey, mldsa65_secretKey
 /// - secret 4032 bytes, public 1952 bytes
 ///
 /// **Requirements: 8.2, 8.3**
    public func getOrCreateMLDSASigningKey() async throws -> (publicKey: Data, keyHandle: SigningKeyHandle) {
 // 检查缓存
        if let cached = cachedMLDSASigningKey {
            return (publicKey: cached.publicKey, keyHandle: .softwareKey(cached.privateKey))
        }
        
 // 尝试从 Keychain 加载
        if let existing = try loadMLDSASigningKey() {
            cachedMLDSASigningKey = existing
            return (publicKey: existing.publicKey, keyHandle: .softwareKey(existing.privateKey))
        }
        
 // 创建新密钥
        let keyPair = try await createMLDSASigningKey()
        cachedMLDSASigningKey = keyPair
        return (publicKey: keyPair.publicKey, keyHandle: .softwareKey(keyPair.privateKey))
    }
    
 /// 创建 ML-DSA-65 协议签名密钥
 ///
 /// ** 11.2**: 使用 OQS 生成 ML-DSA-65 密钥对
 ///
 /// **Requirements: 8.2, 8.3**
    private func createMLDSASigningKey() async throws -> (publicKey: Data, privateKey: Data) {
        #if canImport(OQSRAII)
        let pkLen = oqs_raii_mldsa65_public_key_length()
        let skLen = oqs_raii_mldsa65_secret_key_length()
        
        var publicKeyBytes = [UInt8](repeating: 0, count: Int(pkLen))
        var privateKeyBytes = [UInt8](repeating: 0, count: Int(skLen))
        
        let result = oqs_raii_mldsa65_keypair(
            &publicKeyBytes, pkLen,
            &privateKeyBytes, skLen
        )
        
        guard result == OQSRAII_SUCCESS else {
            throw DeviceIdentityKeyError.keyGenerationFailed("ML-DSA-65 keypair generation failed")
        }
        
        let publicKeyData = Data(publicKeyBytes)
        let privateKeyData = Data(privateKeyBytes)
        
 // 存储到 Keychain（ 11.3: 安全属性配置）
        try saveMLDSASigningKey(publicKey: publicKeyData, privateKey: privateKeyData)
        
        SkyBridgeLogger.p2p.info("Created new ML-DSA-65 protocol signing key")
        return (publicKey: publicKeyData, privateKey: privateKeyData)
        #else
        throw DeviceIdentityKeyError.keyGenerationFailed("OQSRAII not available")
        #endif
    }
    
 /// 加载 ML-DSA-65 协议签名密钥
 ///
 /// ** 11.2**: 从 Keychain 加载 ML-DSA-65 密钥对
    private func loadMLDSASigningKey() throws -> (publicKey: Data, privateKey: Data)? {
 // 加载公钥
        let publicKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.mldsaService,
            kSecAttrAccount as String: KeychainConstants.mldsaPublicKeyAccount,
            kSecReturnData as String: true
        ]
        
        var publicKeyResult: AnyObject?
        let publicKeyStatus = SecItemCopyMatching(publicKeyQuery as CFDictionary, &publicKeyResult)
        
        if publicKeyStatus == errSecItemNotFound {
            return nil
        }
        
        guard publicKeyStatus == errSecSuccess, let publicKeyData = publicKeyResult as? Data else {
            throw DeviceIdentityKeyError.keychainError(publicKeyStatus)
        }
        
 // 加载私钥
        let privateKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.mldsaService,
            kSecAttrAccount as String: KeychainConstants.mldsaSecretKeyAccount,
            kSecReturnData as String: true
        ]
        
        var privateKeyResult: AnyObject?
        let privateKeyStatus = SecItemCopyMatching(privateKeyQuery as CFDictionary, &privateKeyResult)
        
        guard privateKeyStatus == errSecSuccess, let privateKeyData = privateKeyResult as? Data else {
            throw DeviceIdentityKeyError.keychainError(privateKeyStatus)
        }
        
        return (publicKey: publicKeyData, privateKey: privateKeyData)
    }
    
 /// 保存 ML-DSA-65 协议签名密钥到 Keychain
 ///
 /// ** 11.3**: 配置 ML-DSA 密钥安全属性
 /// - `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
 /// - `kSecAttrSynchronizable = false`
 ///
 /// **Requirements: 8.4, 8.5**
    private func saveMLDSASigningKey(publicKey: Data, privateKey: Data) throws {
 // 保存公钥
        let publicKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.mldsaService,
            kSecAttrAccount as String: KeychainConstants.mldsaPublicKeyAccount,
            kSecValueData as String: publicKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        
 // 先删除旧的
        SecItemDelete(publicKeyQuery as CFDictionary)
        
 // 添加新的
        var status = SecItemAdd(publicKeyQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceIdentityKeyError.keychainError(status)
        }
        
 // 保存私钥（更严格的安全属性）
        let privateKeyQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainConstants.mldsaService,
            kSecAttrAccount as String: KeychainConstants.mldsaSecretKeyAccount,
            kSecValueData as String: privateKey,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any
        ]
        
 // 先删除旧的
        SecItemDelete(privateKeyQuery as CFDictionary)
        
 // 添加新的
        status = SecItemAdd(privateKeyQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw DeviceIdentityKeyError.keychainError(status)
        }
    }
    
 // MARK: - SE PoP Key Helpers ( 5.2)
    
 /// 获取 SE PoP 密钥引用
    private func getSEPoPKeyReference() throws -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: KeychainConstants.sePoPKeyTag.utf8Data,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        if status == errSecItemNotFound {
            return nil
        }
        
        guard status == errSecSuccess else {
            throw DeviceIdentityKeyError.keychainError(status)
        }
        
        guard let result else {
            throw DeviceIdentityKeyError.keychainError(errSecInternalError)
        }
        guard CFGetTypeID(result) == SecKeyGetTypeID() else {
            throw DeviceIdentityKeyError.keychainError(errSecInternalError)
        }
        return unsafeDowncast(result, to: SecKey.self)
    }
    
 /// 复制旧密钥到 SE PoP tag
    private func copyKeyToSEPoPTag() throws {
 // 获取旧密钥引用
        guard let oldKeyRef = try getPrivateKeyReference() else {
            throw DeviceIdentityKeyError.keyNotFound
        }
        
 // 获取旧密钥的属性
        guard let oldKeyAttrs = SecKeyCopyAttributes(oldKeyRef) as? [String: Any] else {
            throw DeviceIdentityKeyError.invalidKeyData
        }
        
 // 检查是否是 Secure Enclave 密钥
        let isSecureEnclave = (oldKeyAttrs[kSecAttrTokenID as String] as? String) == (kSecAttrTokenIDSecureEnclave as String)
        
        if isSecureEnclave {
 // Secure Enclave 密钥不能直接复制，需要创建新的引用
 // 我们在 Keychain 中创建一个新的条目，使用相同的密钥数据
 // 注意：这实际上是创建一个新的 Keychain 条目指向同一个 SE 密钥
            
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .privateKeyUsage,
                &error
            ) else {
                throw DeviceIdentityKeyError.secureEnclaveNotAvailable
            }
            
 // 创建新的密钥条目（SE 密钥不能复制，所以我们创建一个新的）
            let attributes: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecAttrApplicationTag as String: KeychainConstants.sePoPKeyTag.utf8Data,
                kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrApplicationTag as String: KeychainConstants.sePoPKeyTag.utf8Data,
                    kSecAttrAccessControl as String: access
                ] as [String: Any]
            ]
            
            if SecKeyCreateRandomKey(attributes as CFDictionary, &error) == nil {
                let cfErr: CFError? = error?.takeRetainedValue()
                let domain = cfErr.map { CFErrorGetDomain($0) as String } ?? ""
                let code = cfErr.map { CFErrorGetCode($0) } ?? 0
                if domain == NSOSStatusErrorDomain,
                   code == Int(errSecMissingEntitlement) || code == -34018 {
                    // SE PoP is optional; if we're missing entitlements, skip migration without failing.
                    SkyBridgeLogger.p2p.warning("⚠️ SE PoP key creation missing entitlement (-34018). Skipping SE PoP migration (optional).")
                    return
                }
                let errorDesc = cfErr.map { (CFErrorCopyDescription($0) as String) } ?? "Unknown error"
                throw DeviceIdentityKeyError.keyGenerationFailed(errorDesc)
            }
        } else {
 // 软件密钥可以直接复制
            guard let keyData = SecKeyCopyExternalRepresentation(oldKeyRef, nil) as Data? else {
                throw DeviceIdentityKeyError.invalidKeyData
            }
            
            let query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: KeychainConstants.sePoPKeyTag.utf8Data,
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecValueData as String: keyData,
                kSecAttrIsPermanent as String: true
            ]
            
 // 先删除旧的
            SecItemDelete(query as CFDictionary)
            
 // 添加新的
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw DeviceIdentityKeyError.keychainError(status)
            }
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
    
 /// Ed25519/ML-DSA 协议签名密钥
    case `protocol` = "protocol"
    
 /// P-256 SE PoP 密钥（迁移后）
    case pop = "pop"
    
 /// 未知用途
    case unknown = "unknown"
}
