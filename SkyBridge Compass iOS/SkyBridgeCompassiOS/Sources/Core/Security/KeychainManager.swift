//
// KeychainManager.swift
// SkyBridgeCompassiOS
//
// 钥匙串管理器 - 安全的密钥存储
// 与 macOS 版本兼容的 API
//

import Foundation
import Security
import CryptoKit

// MARK: - Keychain Error

/// 钥匙串错误
public enum KeychainError: Error, LocalizedError, Sendable {
    case itemNotFound
    case duplicateItem
    case unexpectedError(OSStatus)
    case encodingError
    case decodingError
    
    public var errorDescription: String? {
        switch self {
        case .itemNotFound: return "钥匙串项目未找到"
        case .duplicateItem: return "钥匙串项目已存在"
        case .unexpectedError(let status): return "钥匙串错误: \(status)"
        case .encodingError: return "编码错误"
        case .decodingError: return "解码错误"
        }
    }
}

// MARK: - Keychain Manager

/// 钥匙串管理器
@available(iOS 17.0, *)
public actor KeychainManager {
    
    public static let shared = KeychainManager()
    
    private init() {}
    
    // MARK: - Test Mode Support
    
    private nonisolated static var useInMemoryKeychain: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }
    
    private nonisolated(unsafe) static var inMemoryStore: [String: Data] = [:]
    private nonisolated static let inMemoryLock = NSLock()
    
    // MARK: - Basic Key Operations
    
    /// 导入密钥
    public nonisolated func importKey(data: Data, service: String, account: String) -> Bool {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return true
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }
    
    /// 导出密钥
    public nonisolated func exportKey(service: String, account: String) -> Data? {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            return data
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return data
    }
    
    /// 删除密钥
    public nonisolated func deleteKey(service: String, account: String) -> Bool {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore.removeValue(forKey: key)
            Self.inMemoryLock.unlock()
            return true
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
    
    // MARK: - Symmetric Key Operations
    
    /// 存储对称密钥
    public nonisolated func storeSymmetricKey(_ key: SymmetricKey, account: String) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        return importKey(data: data, service: "SkyBridge.SymmetricKey", account: account)
    }
    
    /// 加载对称密钥
    public nonisolated func loadSymmetricKey(account: String) -> SymmetricKey? {
        guard let data = exportKey(service: "SkyBridge.SymmetricKey", account: account) else {
            return nil
        }
        return SymmetricKey(data: data)
    }
    
    // MARK: - P256 Key Operations
    
    /// 生成并存储 P256 签名密钥对
    public nonisolated func generateP256SigningKeypair(tag: String) -> (private: P256.Signing.PrivateKey, public: P256.Signing.PublicKey)? {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let privData = privateKey.rawRepresentation
        let pubData = publicKey.rawRepresentation
        
        let ok1 = importKey(data: privData, service: "SkyBridge.P256Priv", account: tag)
        let ok2 = importKey(data: pubData, service: "SkyBridge.P256Pub", account: tag)
        
        if !ok1 || !ok2 {
            return nil
        }
        
        return (privateKey, publicKey)
    }
    
    /// 加载 P256 私钥
    public nonisolated func loadP256PrivateKey(tag: String) -> P256.Signing.PrivateKey? {
        guard let data = exportKey(service: "SkyBridge.P256Priv", account: tag) else {
            return nil
        }
        return try? P256.Signing.PrivateKey(rawRepresentation: data)
    }
    
    /// 加载 P256 公钥
    public nonisolated func loadP256PublicKey(tag: String) -> P256.Signing.PublicKey? {
        guard let data = exportKey(service: "SkyBridge.P256Pub", account: tag) else {
            return nil
        }
        return try? P256.Signing.PublicKey(rawRepresentation: data)
    }
    
    /// 生成 P256 密钥交换密钥对
    public nonisolated func generateP256KeyAgreementKeypair(tag: String) -> (private: P256.KeyAgreement.PrivateKey, public: P256.KeyAgreement.PublicKey)? {
        let privateKey = P256.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let privData = privateKey.rawRepresentation
        let pubData = publicKey.rawRepresentation
        
        let ok1 = importKey(data: privData, service: "SkyBridge.P256KAPriv", account: tag)
        let ok2 = importKey(data: pubData, service: "SkyBridge.P256KAPub", account: tag)
        
        if !ok1 || !ok2 {
            return nil
        }
        
        return (privateKey, publicKey)
    }
    
    /// 加载 P256 密钥交换私钥
    public nonisolated func loadP256KeyAgreementPrivateKey(tag: String) -> P256.KeyAgreement.PrivateKey? {
        guard let data = exportKey(service: "SkyBridge.P256KAPriv", account: tag) else {
            return nil
        }
        return try? P256.KeyAgreement.PrivateKey(rawRepresentation: data)
    }
    
    // MARK: - Curve25519 Key Operations
    
    /// 生成并存储 Curve25519 签名密钥对
    public nonisolated func generateCurve25519SigningKeypair(tag: String) -> (private: Curve25519.Signing.PrivateKey, public: Curve25519.Signing.PublicKey)? {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let privData = privateKey.rawRepresentation
        let pubData = publicKey.rawRepresentation
        
        let ok1 = importKey(data: privData, service: "SkyBridge.Ed25519Priv", account: tag)
        let ok2 = importKey(data: pubData, service: "SkyBridge.Ed25519Pub", account: tag)
        
        if !ok1 || !ok2 {
            return nil
        }
        
        return (privateKey, publicKey)
    }
    
    /// 加载 Curve25519 签名私钥
    public nonisolated func loadCurve25519SigningPrivateKey(tag: String) -> Curve25519.Signing.PrivateKey? {
        guard let data = exportKey(service: "SkyBridge.Ed25519Priv", account: tag) else {
            return nil
        }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data)
    }
    
    /// 加载 Curve25519 签名公钥
    public nonisolated func loadCurve25519SigningPublicKey(tag: String) -> Curve25519.Signing.PublicKey? {
        guard let data = exportKey(service: "SkyBridge.Ed25519Pub", account: tag) else {
            return nil
        }
        return try? Curve25519.Signing.PublicKey(rawRepresentation: data)
    }
    
    /// 生成 X25519 密钥交换密钥对
    public nonisolated func generateX25519Keypair(tag: String) -> (private: Curve25519.KeyAgreement.PrivateKey, public: Curve25519.KeyAgreement.PublicKey)? {
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let publicKey = privateKey.publicKey
        
        let privData = privateKey.rawRepresentation
        let pubData = publicKey.rawRepresentation
        
        let ok1 = importKey(data: privData, service: "SkyBridge.X25519Priv", account: tag)
        let ok2 = importKey(data: pubData, service: "SkyBridge.X25519Pub", account: tag)
        
        if !ok1 || !ok2 {
            return nil
        }
        
        return (privateKey, publicKey)
    }
    
    /// 加载 X25519 私钥
    public nonisolated func loadX25519PrivateKey(tag: String) -> Curve25519.KeyAgreement.PrivateKey? {
        guard let data = exportKey(service: "SkyBridge.X25519Priv", account: tag) else {
            return nil
        }
        return try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data)
    }
    
    // MARK: - Peer Key Storage
    
    /// 存储对端签名公钥
    public nonisolated func storePeerSigningPublicKey(_ keyData: Data, peerId: String) -> Bool {
        importKey(data: keyData, service: "SkyBridge.PeerSigningPub", account: peerId)
    }
    
    /// 获取对端签名公钥
    public nonisolated func retrievePeerSigningPublicKey(_ peerId: String) -> Data? {
        exportKey(service: "SkyBridge.PeerSigningPub", account: peerId)
    }
    
    // MARK: - Device Identity
    
    /// 获取或生成设备 ID
    public nonisolated func getOrGenerateDeviceId() -> String {
        let service = "SkyBridge.Identity"
        let account = "DeviceUUID"
        
        if let data = exportKey(service: service, account: account),
           let uuidString = String(data: data, encoding: .utf8) {
            return uuidString
        }
        
        let newUUID = UUID().uuidString
        if let data = newUUID.data(using: .utf8) {
            _ = importKey(data: data, service: service, account: account)
        }
        return newUUID
    }
    
    // MARK: - Session Key Storage
    
    /// 存储会话密钥
    public nonisolated func storeSessionKey(_ key: SymmetricKey, sessionId: String) -> Bool {
        storeSymmetricKey(key, account: "Session.\(sessionId)")
    }
    
    /// 加载会话密钥
    public nonisolated func loadSessionKey(sessionId: String) -> SymmetricKey? {
        loadSymmetricKey(account: "Session.\(sessionId)")
    }
    
    /// 删除会话密钥
    public nonisolated func deleteSessionKey(sessionId: String) -> Bool {
        deleteKey(service: "SkyBridge.SymmetricKey", account: "Session.\(sessionId)")
    }
    
    // MARK: - API Key Storage
    
    /// 存储 API 密钥
    public nonisolated func storeAPIKey(_ key: String, service: String, account: String) throws {
        guard let data = key.data(using: .utf8) else {
            throw KeychainError.encodingError
        }
        
        if !importKey(data: data, service: service, account: account) {
            throw KeychainError.unexpectedError(-1)
        }
    }
    
    /// 获取 API 密钥
    public nonisolated func retrieveAPIKey(service: String, account: String) throws -> String {
        guard let data = exportKey(service: service, account: account),
              let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.itemNotFound
        }
        return key
    }
    
    // MARK: - Cleanup
    
    /// 清理过期的会话密钥
    public nonisolated func cleanupExpiredSessionKeys() {
        // 在内存模式下，清理所有 Session 开头的密钥
        if Self.useInMemoryKeychain {
            Self.inMemoryLock.lock()
            Self.inMemoryStore = Self.inMemoryStore.filter { !$0.key.contains("Session.") }
            Self.inMemoryLock.unlock()
            return
        }
        
        // 在真实 Keychain 中，需要遍历并删除
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "SkyBridge.SymmetricKey",
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        
        guard status == errSecSuccess,
              let itemList = items as? [[String: Any]] else {
            return
        }
        
        for item in itemList {
            guard let account = item[kSecAttrAccount as String] as? String,
                  account.hasPrefix("Session.") else {
                continue
            }
            
            _ = deleteKey(service: "SkyBridge.SymmetricKey", account: account)
        }
    }
}

// MARK: - Generic Password (no-service) helpers

@available(iOS 17.0, *)
private extension KeychainManager {
    /// Save a generic password item addressed only by account (for backward compatibility with older storage).
    func saveGenericPassword(account: String, data: Data) throws {
        if Self.useInMemoryKeychain {
            let key = "GenericPassword|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedError(status)
        }
    }
    
    /// Load a generic password item addressed only by account (for backward compatibility with older storage).
    func loadGenericPassword(account: String) throws -> Data {
        if Self.useInMemoryKeychain {
            let key = "GenericPassword|" + account
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            guard let data else { throw KeychainError.itemNotFound }
            return data
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.itemNotFound
        }
        return data
    }
    
    func deleteGenericPassword(account: String) {
        if Self.useInMemoryKeychain {
            let key = "GenericPassword|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore.removeValue(forKey: key)
            Self.inMemoryLock.unlock()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - PQC Key Storage (compat with PQCCryptoManager identifiers)

@available(iOS 17.0, *)
public extension KeychainManager {
    nonisolated func savePrivateKey(_ key: Data, identifier: String) throws {
        try saveGenericPasswordSync(account: identifier, data: key)
    }
    
    nonisolated func savePublicKey(_ key: Data, identifier: String) throws {
        try saveGenericPasswordSync(account: identifier, data: key)
    }
    
    nonisolated func loadPrivateKey(identifier: String) throws -> Data {
        try loadGenericPasswordSync(account: identifier)
    }
    
    nonisolated func loadPublicKey(identifier: String) throws -> Data {
        try loadGenericPasswordSync(account: identifier)
    }
    
    nonisolated func deleteKey(identifier: String) {
        deleteGenericPasswordSync(account: identifier)
    }
    
    // MARK: - Sync helpers for nonisolated access
    
    private nonisolated func saveGenericPasswordSync(account: String, data: Data) throws {
        if Self.useInMemoryKeychain {
            let key = "GenericPassword|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedError(status)
        }
    }
    
    private nonisolated func loadGenericPasswordSync(account: String) throws -> Data {
        if Self.useInMemoryKeychain {
            let key = "GenericPassword|" + account
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[key]
            Self.inMemoryLock.unlock()
            guard let data else { throw KeychainError.itemNotFound }
            return data
        }
        
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError.itemNotFound
        }
        return data
    }
    
    private nonisolated func deleteGenericPasswordSync(account: String) {
        if Self.useInMemoryKeychain {
            let key = "GenericPassword|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore.removeValue(forKey: key)
            Self.inMemoryLock.unlock()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - Supabase / Auth config (与 macOS 端同构)

@available(iOS 17.0, *)
public extension KeychainManager {
    struct SupabaseConfig: Codable, Sendable {
        public let url: String
        public let anonKey: String
        
        public init(url: String, anonKey: String) {
            self.url = url
            self.anonKey = anonKey
        }
    }
    
    nonisolated func storeSupabaseConfig(url: String, anonKey: String) throws {
        let urlTrimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let anonTrimmed = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)
        try saveGenericPasswordSync(account: "supabase.url", data: Data(urlTrimmed.utf8))
        try saveGenericPasswordSync(account: "supabase.anonKey", data: Data(anonTrimmed.utf8))
        
        // Compatibility: also store under the macOS-style service/account keys so iOS/macOS stay aligned conceptually.
        // This also helps when users switch between older/newer builds that used different key naming.
        _ = importKey(data: Data(urlTrimmed.utf8), service: "SkyBridge.Supabase", account: "URL")
        _ = importKey(data: Data(anonTrimmed.utf8), service: "SkyBridge.Supabase", account: "AnonKey")
        
        // SECURITY: Never store a Supabase service-role key on client devices.
        deleteGenericPasswordSync(account: "supabase.serviceRoleKey")
        _ = deleteKey(service: "SkyBridge.Supabase", account: "ServiceRoleKey")
    }
    
    nonisolated func retrieveSupabaseConfig() throws -> SupabaseConfig {
        do {
            let urlData = try loadGenericPasswordSync(account: "supabase.url")
            let anonData = try loadGenericPasswordSync(account: "supabase.anonKey")
            guard let url = String(data: urlData, encoding: .utf8),
                  let anon = String(data: anonData, encoding: .utf8) else {
                throw KeychainError.decodingError
            }
            // Best-effort: clean up any legacy stored service role key.
            deleteGenericPasswordSync(account: "supabase.serviceRoleKey")
            _ = deleteKey(service: "SkyBridge.Supabase", account: "ServiceRoleKey")
            return SupabaseConfig(url: url, anonKey: anon)
        } catch {
            // Fallback: macOS-style keys (service-based)
            if let urlData = exportKey(service: "SkyBridge.Supabase", account: "URL"),
               let anonData = exportKey(service: "SkyBridge.Supabase", account: "AnonKey"),
               let url = String(data: urlData, encoding: .utf8),
               let anon = String(data: anonData, encoding: .utf8) {
                // Migrate forward to the current iOS storage keys for next launch.
                try? storeSupabaseConfig(url: url, anonKey: anon)
                return SupabaseConfig(url: url, anonKey: anon)
            }
            throw error
        }
    }

    /// 清除 Supabase 配置（用于从占位符/错误配置恢复）
    nonisolated func deleteSupabaseConfig() {
        deleteGenericPasswordSync(account: "supabase.url")
        deleteGenericPasswordSync(account: "supabase.anonKey")
        deleteGenericPasswordSync(account: "supabase.serviceRoleKey")
        _ = deleteKey(service: "SkyBridge.Supabase", account: "URL")
        _ = deleteKey(service: "SkyBridge.Supabase", account: "AnonKey")
        _ = deleteKey(service: "SkyBridge.Supabase", account: "ServiceRoleKey")
    }
    
    nonisolated func storeAuthSession(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        try saveGenericPasswordSync(account: "auth.session", data: data)
    }
    
    nonisolated func loadAuthSession() -> AuthSession? {
        guard let data = try? loadGenericPasswordSync(account: "auth.session") else { return nil }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }
    
    nonisolated func deleteAuthSession() {
        deleteGenericPasswordSync(account: "auth.session")
    }
}

