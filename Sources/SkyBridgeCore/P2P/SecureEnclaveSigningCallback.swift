//
// SecureEnclaveSigningCallback.swift
// SkyBridgeCore
//
// P2P Completion - 4: Secure Enclave Signing Callback
// Requirements: 2.3, 2.4
//
// Secure Enclave 签名回调实现：
// - 从 Keychain 获取 Secure Enclave 密钥
// - 使用 SecKeyCreateSignature 进行签名
// - 失败时记录降级路径（不保证在 pinning 语义下“换钥继续签”仍能通过验证）
//

import Foundation
import Security

// MARK: - SecureEnclaveSigningCallback

/// Secure Enclave 签名回调实现
///
/// 使用 Secure Enclave 中存储的密钥进行签名操作。
/// 私钥永远不会离开硬件安全模块。
///
/// **Requirements: 2.3**
///
/// **使用方式**:
/// ```swift
/// let callback = SecureEnclaveSigningCallback(keyTag: "com.skybridge.identity")
/// let driver = HandshakeDriver(
/// transport: transport,
/// cryptoProvider: provider,
/// identityPublicKey: publicKey,
/// signingCallback: callback
/// )
/// ```
///
/// **注意**: 此实现仅使用 Secure Enclave 的 P-256/ECDSA。
/// 需要 ML-DSA 时请使用 CryptoKit 的 SecureEnclave.MLDSA* 类型（仅 macOS 26+ 可用）。
@available(macOS 14.0, iOS 17.0, *)
public struct SecureEnclaveSigningCallback: SigningCallback, Sendable {
    
 // MARK: - Properties
    
 /// Keychain 中密钥的标签
    private let keyTag: String
    
 /// 签名算法（默认使用 ECDSA P-256）
    private let algorithm: SecKeyAlgorithm
    
 // MARK: - Initialization
    
 /// 初始化 Secure Enclave 签名回调
 ///
 /// - Parameters:
 /// - keyTag: Keychain 中密钥的标签（Application Tag）
 /// - algorithm: 签名算法，默认为 ECDSA P-256
    public init(
        keyTag: String,
        algorithm: SecKeyAlgorithm = .ecdsaSignatureMessageX962SHA256
    ) {
        self.keyTag = keyTag
        self.algorithm = algorithm
    }
    
 // MARK: - SigningCallback
    
 /// 使用 Secure Enclave 密钥签名数据
 ///
 /// - Parameter data: 要签名的数据
 /// - Returns: 签名结果
 /// - Throws: SecureEnclaveError 如果签名失败
    public func sign(data: Data) async throws -> Data {
 // 从 Keychain 获取私钥引用
        let privateKey = try getPrivateKey()
        
 // 验证算法支持
        guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
            throw SecureEnclaveError.algorithmNotSupported(algorithm.rawValue as String)
        }
        
 // 执行签名
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            algorithm,
            data as CFData,
            &error
        ) else {
            let errorDescription = error?.takeRetainedValue().localizedDescription ?? "Unknown error"
            throw SecureEnclaveError.signatureFailed(errorDescription)
        }
        
        return signature as Data
    }
    
 // MARK: - Private Methods
    
 /// 从 Keychain 获取私钥引用
 ///
 /// - Returns: SecKey 私钥引用
 /// - Throws: SecureEnclaveError 如果密钥不存在或无法访问
    private func getPrivateKey() throws -> SecKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag.utf8Data,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess else {
            throw SecureEnclaveError.keyNotFound(keyTag, status)
        }
        
        guard let item else {
            throw SecureEnclaveError.invalidKeyReference
        }
        guard CFGetTypeID(item) == SecKeyGetTypeID() else {
            throw SecureEnclaveError.invalidKeyReference
        }
        let privateKey = unsafeDowncast(item, to: SecKey.self)
        
        return privateKey
    }
}

// MARK: - SecureEnclaveError

/// Secure Enclave 操作错误
public enum SecureEnclaveError: Error, LocalizedError, Sendable {
 /// 密钥未找到
    case keyNotFound(String, OSStatus)
    
 /// 无效的密钥引用
    case invalidKeyReference
    
 /// 算法不支持
    case algorithmNotSupported(String)
    
 /// 签名失败
    case signatureFailed(String)
    
 /// Secure Enclave 不可用
    case secureEnclaveUnavailable
    
 /// 密钥生成失败
    case keyGenerationFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .keyNotFound(let tag, let status):
            return "Secure Enclave key not found: \(tag) (status: \(status))"
        case .invalidKeyReference:
            return "Invalid Secure Enclave key reference"
        case .algorithmNotSupported(let alg):
            return "Algorithm not supported by Secure Enclave: \(alg)"
        case .signatureFailed(let reason):
            return "Secure Enclave signature failed: \(reason)"
        case .secureEnclaveUnavailable:
            return "Secure Enclave is not available on this device"
        case .keyGenerationFailed(let reason):
            return "Secure Enclave key generation failed: \(reason)"
        }
    }
}

// MARK: - SecureEnclaveKeyManager

/// Secure Enclave 密钥管理器
///
/// 提供密钥生成、检查和删除功能。
@available(macOS 14.0, iOS 17.0, *)
public enum SecureEnclaveKeyManager {

    private static var useInMemoryKeychain: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }
    
 /// 检查 Secure Enclave 是否可用
 ///
 /// - Returns: true 如果 Secure Enclave 可用
    public static func isSecureEnclaveAvailable() -> Bool {
 // 检查设备是否支持 Secure Enclave
 // 所有 Apple Silicon Mac 和 A7+ iOS 设备都支持
        #if targetEnvironment(simulator)
        return false  // 模拟器不支持 Secure Enclave
        #else
 // 尝试创建一个临时的 Secure Enclave 密钥来验证可用性
        let testTag = "com.skybridge.secureenclave.availability.test"
        
 // 先清理可能存在的测试密钥
        deleteKey(tag: testTag)
        
 // 尝试生成测试密钥
        do {
            _ = try generateKey(tag: testTag, requireSecureEnclave: true)
 // 清理测试密钥
            deleteKey(tag: testTag)
            return true
        } catch {
            return false
        }
        #endif
    }
    
 /// 检查指定标签的密钥是否存在
 ///
 /// - Parameter tag: 密钥标签
 /// - Returns: true 如果密钥存在
    public static func keyExists(tag: String) -> Bool {
        if useInMemoryKeychain { return false }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.utf8Data,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
 /// 生成 Secure Enclave 密钥对
 ///
 /// - Parameters:
 /// - tag: 密钥标签
 /// - requireSecureEnclave: 是否强制要求 Secure Enclave
 /// - Returns: 公钥数据
 /// - Throws: SecureEnclaveError 如果生成失败
    public static func generateKey(
        tag: String,
        requireSecureEnclave: Bool = true
    ) throws -> Data {
 // 构建密钥属性
        var privateKeyAttrs: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: tag.utf8Data
        ]
        
        var keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: privateKeyAttrs
        ]
        
 // 如果要求 Secure Enclave，添加相关属性
        if requireSecureEnclave {
            #if !targetEnvironment(simulator)
 // 创建访问控制
            var error: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .privateKeyUsage,
                &error
            ) else {
                let errorDesc = error?.takeRetainedValue().localizedDescription ?? "Unknown"
                throw SecureEnclaveError.keyGenerationFailed("Access control creation failed: \(errorDesc)")
            }
            
            privateKeyAttrs[kSecAttrAccessControl as String] = access
            keyAttrs[kSecPrivateKeyAttrs as String] = privateKeyAttrs
            keyAttrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
            #else
            throw SecureEnclaveError.secureEnclaveUnavailable
            #endif
        }
        
 // 生成密钥对
        var genError: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttrs as CFDictionary, &genError) else {
            let errorDesc = genError?.takeRetainedValue().localizedDescription ?? "Unknown"
            throw SecureEnclaveError.keyGenerationFailed(errorDesc)
        }
        
 // 获取公钥
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveError.keyGenerationFailed("Failed to extract public key")
        }
        
 // 导出公钥数据
        var exportError: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &exportError) else {
            let errorDesc = exportError?.takeRetainedValue().localizedDescription ?? "Unknown"
            throw SecureEnclaveError.keyGenerationFailed("Failed to export public key: \(errorDesc)")
        }
        
        return publicKeyData as Data
    }
    
 /// 删除指定标签的密钥
 ///
 /// - Parameter tag: 密钥标签
 /// - Returns: true 如果删除成功或密钥不存在
    @discardableResult
    public static func deleteKey(tag: String) -> Bool {
        if useInMemoryKeychain { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.utf8Data,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
 /// 获取公钥数据
 ///
 /// - Parameter tag: 密钥标签
 /// - Returns: 公钥数据
 /// - Throws: SecureEnclaveError 如果密钥不存在
    public static func getPublicKey(tag: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.utf8Data,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess, let item else {
            throw SecureEnclaveError.keyNotFound(tag, status)
        }
        guard CFGetTypeID(item) == SecKeyGetTypeID() else {
            throw SecureEnclaveError.invalidKeyReference
        }
        let privateKey = unsafeDowncast(item, to: SecKey.self)
        
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw SecureEnclaveError.invalidKeyReference
        }
        
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            let errorDesc = error?.takeRetainedValue().localizedDescription ?? "Unknown"
            throw SecureEnclaveError.signatureFailed("Failed to export public key: \(errorDesc)")
        }
        
        return publicKeyData as Data
    }
}


// MARK: - FallbackSigningCallback

/// 带 Fallback 的签名回调
///
/// 优先使用 Secure Enclave 签名；失败时可切换到软件签名路径，并记录降级事件用于观测。
///
/// **Requirements: 2.4**
///
/// **Fallback 策略**:
/// 1. 首先尝试使用 Secure Enclave 签名
/// 2. 如果 Secure Enclave 不可用或签名失败，使用 CryptoProvider
/// 3. 记录降级事件用于监控/排障
///
/// **重要**: 在 identity pinning 语义下，回退到“另一把私钥”通常无法通过对端验签或 pinning。
/// 是否允许回退必须由调用方确保 `identityPublicKey` 与当前实际签名密钥一致；本类型不做语义放水。
///
/// **使用方式**:
/// ```swift
/// let callback = FallbackSigningCallback(
/// keyTag: "com.skybridge.identity",
/// fallbackProvider: CryptoProviderFactory.make(),
/// fallbackPrivateKey: privateKeyData
/// )
/// ```
@available(macOS 14.0, iOS 17.0, *)
public final class FallbackSigningCallback: SigningCallback, @unchecked Sendable {
    
 // MARK: - Properties
    
 /// Secure Enclave 密钥标签
    private let keyTag: String
    
 /// Fallback CryptoProvider
    private let fallbackProvider: any CryptoProvider
    
 /// Fallback 私钥数据
    private let fallbackPrivateKey: Data
    
 /// 签名算法
    private let algorithm: SecKeyAlgorithm
    
 /// 是否已检测到 Secure Enclave 不可用
    private var secureEnclaveUnavailable: Bool = false
    
 /// 用于线程安全的锁
    private let lock = NSLock()
    
 // MARK: - Initialization
    
 /// 初始化带 Fallback 的签名回调
 ///
 /// - Parameters:
 /// - keyTag: Secure Enclave 密钥标签
 /// - fallbackProvider: Fallback CryptoProvider
 /// - fallbackPrivateKey: Fallback 私钥数据
 /// - algorithm: 签名算法
    public init(
        keyTag: String,
        fallbackProvider: any CryptoProvider,
        fallbackPrivateKey: Data,
        algorithm: SecKeyAlgorithm = .ecdsaSignatureMessageX962SHA256
    ) {
        self.keyTag = keyTag
        self.fallbackProvider = fallbackProvider
        self.fallbackPrivateKey = fallbackPrivateKey
        self.algorithm = algorithm
    }
    
 // MARK: - SigningCallback
    
 /// 签名数据（带 Fallback）
 ///
 /// - Parameter data: 要签名的数据
 /// - Returns: 签名结果
 /// - Throws: 如果所有签名方式都失败
    public func sign(data: Data) async throws -> Data {
 // 检查是否已知 Secure Enclave 不可用
        let shouldSkipSecureEnclave: Bool = {
            lock.lock()
            defer { lock.unlock() }
            return secureEnclaveUnavailable
        }()
        
        if !shouldSkipSecureEnclave {
 // 尝试 Secure Enclave 签名
            do {
                let secureEnclaveCallback = SecureEnclaveSigningCallback(
                    keyTag: keyTag,
                    algorithm: algorithm
                )
                return try await secureEnclaveCallback.sign(data: data)
            } catch let error as SecureEnclaveError {
 // 记录 Secure Enclave 失败
                handleSecureEnclaveFailure(error)
            } catch {
 // 其他错误也触发 fallback
                SkyBridgeLogger.p2p.warning("Secure Enclave signing failed with unexpected error: \(error.localizedDescription)")
            }
        }
        
 // Fallback 到 CryptoProvider
        SkyBridgeLogger.p2p.info("Using CryptoProvider fallback for signing (may not satisfy identity pinning)")
        return try await fallbackProvider.sign(data: data, using: .softwareKey(fallbackPrivateKey))
    }
    
 // MARK: - Private Methods
    
 /// 处理 Secure Enclave 失败
    private func handleSecureEnclaveFailure(_ error: SecureEnclaveError) {
 // 记录失败原因
        SkyBridgeLogger.p2p.warning("Secure Enclave signing failed: \(error.localizedDescription)")
        
 // 对于某些错误，标记 Secure Enclave 为不可用以避免重复尝试
        switch error {
        case .keyNotFound, .secureEnclaveUnavailable, .algorithmNotSupported:
            lock.lock()
            secureEnclaveUnavailable = true
            lock.unlock()
            
 // 发射安全事件
            SecurityEventEmitter.emitDetached(SecurityEvent(
                type: .cryptoProviderSelected,
                severity: .warning,
                message: "Falling back from Secure Enclave to CryptoProvider",
                context: [
                    "reason": error.errorDescription ?? "Unknown error",
                    "keyTag": keyTag
                ]
            ))
            
        case .signatureFailed, .invalidKeyReference, .keyGenerationFailed:
 // 这些错误可能是临时的，不标记为不可用
            break
        }
    }
    
 /// 重置 Secure Enclave 可用性状态（用于测试或重试）
    public func resetSecureEnclaveStatus() {
        lock.lock()
        secureEnclaveUnavailable = false
        lock.unlock()
    }
}

// MARK: - Convenience Factory

@available(macOS 14.0, iOS 17.0, *)
extension FallbackSigningCallback {
    
 /// 创建带自动 Fallback 的签名回调
 ///
 /// 如果 Secure Enclave 可用且密钥存在，使用 Secure Enclave。
 /// 否则使用 CryptoProvider（调用方仍需保证 pinning 语义一致）。
 ///
 /// - Parameters:
 /// - keyTag: Secure Enclave 密钥标签
 /// - fallbackProvider: Fallback CryptoProvider
 /// - fallbackPrivateKey: Fallback 私钥数据
 /// - Returns: 签名回调
    public static func create(
        keyTag: String,
        fallbackProvider: any CryptoProvider,
        fallbackPrivateKey: Data
    ) -> any SigningCallback {
 // 检查 Secure Enclave 是否可用且密钥存在
        if SecureEnclaveKeyManager.isSecureEnclaveAvailable() &&
           SecureEnclaveKeyManager.keyExists(tag: keyTag) {
 // 使用带 Fallback 的回调
            return FallbackSigningCallback(
                keyTag: keyTag,
                fallbackProvider: fallbackProvider,
                fallbackPrivateKey: fallbackPrivateKey
            )
        } else {
 // Secure Enclave 不可用，直接使用 CryptoProvider 包装
            return CryptoProviderSigningCallback(
                provider: fallbackProvider,
                privateKey: fallbackPrivateKey
            )
        }
    }
}

// MARK: - CryptoProviderSigningCallback

/// CryptoProvider 签名回调包装器
///
/// 将 CryptoProvider 包装为 SigningCallback 接口。
@available(macOS 14.0, iOS 17.0, *)
public struct CryptoProviderSigningCallback: SigningCallback, Sendable {
    
 /// CryptoProvider
    private let provider: any CryptoProvider
    
 /// 私钥数据
    private let privateKey: Data
    
 /// 初始化
 ///
 /// - Parameters:
 /// - provider: CryptoProvider
 /// - privateKey: 私钥数据
    public init(provider: any CryptoProvider, privateKey: Data) {
        self.provider = provider
        self.privateKey = privateKey
    }
    
 /// 签名数据
    public func sign(data: Data) async throws -> Data {
        return try await provider.sign(data: data, using: .softwareKey(privateKey))
    }
}
