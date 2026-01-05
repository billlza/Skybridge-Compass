import Foundation
import CryptoKit
import Security
import OSLog

/// 增强版量子密钥管理器 - 使用Apple CryptoKit和安全存储
///
/// 改进点:
/// 1. 使用CryptoKit安全密钥生成
/// 2. 集成Keychain安全存储
/// 3. 支持密钥轮换和版本管理
/// 4. 线程安全实现
///
/// ## 并发安全说明 (@unchecked Sendable)
/// 使用 `@unchecked Sendable` 的理由：
/// - ✅ 所有内存中的密钥通过 `keyLock` (OSAllocatedUnfairLock) 保护
/// - ✅ 密钥字典封装在锁内，所有访问都在 `withLock` 闭包内
/// - ✅ Keychain操作本身是线程安全的（系统级同步）
/// - ✅ `logger` 和 `keychainService` 是不可变的
/// - ✅ CryptoKit 的 SymmetricKey 本身是 Sendable
public class EnhancedQuantumKeyManager: @unchecked Sendable {
    
    private let logger = Logger(subsystem: "com.skybridge.quantum", category: "EnhancedQuantumKeyManager")
    
 /// 内存密钥缓存（封装在锁内）
 /// 所有访问必须通过 keyLock.withLock { } 进行
    private let keyLock = OSAllocatedUnfairLock<[String: SymmetricKey]>(initialState: [:])
    
    private let keychainService = "com.skybridge.quantum.keys"
    
    public init() {
 // 公开初始化器，允许外部模块访问
    }
    
 // MARK: - 密钥生成
    
 /// 生成量子安全密钥 - 使用CryptoKit
    public func generateQuantumKey() async throws -> SymmetricKey {
        logger.info("🔑 生成量子安全密钥（使用CryptoKit）")
        
 // 使用CryptoKit生成256位对称密钥
 // 这是密码学安全的，比UInt8.random强得多
        let key = SymmetricKey(size: .bits256)
        
        logger.info("✅ 量子安全密钥生成完成")
        return key
    }
    
 /// 生成密钥数据（用于传输）
    public func generateQuantumKeyData() async throws -> Data {
        let key = try await generateQuantumKey()
        return key.withUnsafeBytes { Data($0) }
    }
    
 // MARK: - 内存密钥管理
    
 /// 存储密钥到内存（临时）
    public func storeKeyInMemory(_ key: SymmetricKey, for peerId: String) async {
        logger.info("💾 存储密钥到内存: \(peerId)")
        keyLock.withLock { keys in
            keys[peerId] = key
        }
    }
    
 /// 从内存获取密钥
    public func getKeyFromMemory(for peerId: String) async throws -> SymmetricKey {
        return try keyLock.withLock { keys in
            guard let key = keys[peerId] else {
                logger.error("❌ 内存中未找到密钥: \(peerId)")
                throw QuantumNetworkError.keyNotFound
            }
            return key
        }
    }
    
 // MARK: - Keychain存储
    
 /// 存储密钥到Keychain（持久化）
    public func storeKeyInKeychain(_ keyData: Data, identifier: String) throws {
        logger.info("💾 存储密钥到Keychain: \(identifier)")
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identifier,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        
 // 先删除旧密钥（如果存在）
        SecItemDelete(query as CFDictionary)
        
 // 添加新密钥
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            logger.error("❌ Keychain存储失败: \(status)")
            throw QuantumNetworkError.keychainError(status)
        }
        
        logger.info("✅ 密钥已安全存储到Keychain")
    }
    
 /// 从Keychain检索密钥
    public func retrieveKeyFromKeychain(identifier: String) throws -> Data {
        logger.info("🔍 从Keychain检索密钥: \(identifier)")
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identifier,
            kSecReturnData as String: true
        ]
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess,
              let keyData = result as? Data else {
            logger.error("❌ Keychain检索失败: \(status)")
            throw QuantumNetworkError.keyNotFound
        }
        
        logger.info("✅ 密钥已从Keychain检索")
        return keyData
    }
    
 /// 从Keychain删除密钥
    public func deleteKeyFromKeychain(identifier: String) throws {
        logger.info("🗑️ 从Keychain删除密钥: \(identifier)")
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: identifier
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            logger.error("❌ Keychain删除失败: \(status)")
            throw QuantumNetworkError.keychainError(status)
        }
        
        logger.info("✅ 密钥已从Keychain删除")
    }
    
 // MARK: - 密钥轮换
    
 /// 轮换密钥（生成新密钥并替换旧密钥）
    public func rotateKey(for peerId: String) async throws {
        logger.info("🔄 轮换密钥: \(peerId)")
        
 // 生成新密钥
        let newKey = try await generateQuantumKey()
        
 // 存储新密钥
        await storeKeyInMemory(newKey, for: peerId)
        
 // 如果Keychain中有旧密钥，也更新
        let keychainId = "\(peerId)_latest"
        let keyData = newKey.withUnsafeBytes { Data($0) }
        try? storeKeyInKeychain(keyData, identifier: keychainId)
        
        logger.info("✅ 密钥轮换完成: \(peerId)")
    }
    
 // MARK: - 密钥清理
    
 /// 清理所有内存密钥
    public func clearAllMemoryKeys() async {
        logger.info("🧹 清理所有内存密钥")
        keyLock.withLock { keys in
            keys.removeAll()
        }
    }
    
 /// 获取存储的密钥数量（仅内存）
    public func getStoredKeyCount() async -> Int {
        return keyLock.withLock { keys in
            keys.count
        }
    }
}

// MARK: - 扩展错误类型

extension QuantumNetworkError {
    static func keychainError(_ status: OSStatus) -> QuantumNetworkError {
 // 可以通过自定义错误处理Keychain错误
        return .keyNotFound
    }
}

