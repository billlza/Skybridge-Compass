import Foundation
import Security
import CryptoKit
import OSLog

/// KeychainManager - 安全的密钥存储管理器
///
/// ## 并发安全说明
/// ✅ 使用 Actor 隔离，但 Keychain 操作标记为 nonisolated
/// ✅ 移除 @MainActor - Keychain IO 不应该阻塞主线程
/// ✅ Keychain API 本身是线程安全的（系统级同步）
/// ✅ 仅对需要协调的操作（如 deduplicate）使用 actor 隔离
@available(macOS 14.0, *)
public actor KeychainManager {
    public static let shared = KeychainManager()
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "KeychainManager")
    private init() {}

    private nonisolated static var useInMemoryKeychain: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }
    private nonisolated(unsafe) static var inMemoryStore: [String: Data] = [:]
    private nonisolated static let inMemoryLock = NSLock()

 // MARK: - Keychain 基础操作（nonisolated - Keychain 本身线程安全）

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
        if status != errSecSuccess { logger.error("Key 导入失败: \(status)") }
        return status == errSecSuccess
    }

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
            if status != errSecItemNotFound { logger.error("Key 导出失败: \(status)") }
            return nil
        }
        return data
    }

 // MARK: - 对称密钥存取（AES-GCM等）

    public nonisolated func storeSymmetricKey(_ key: SymmetricKey, account: String) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        if Self.useInMemoryKeychain {
            let memKey = "SkyBridge.SymmetricKey" + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[memKey] = data
            Self.inMemoryLock.unlock()
            return true
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "SkyBridge.SymmetricKey",
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { logger.error("对称密钥存储失败: \(status)") }
        return status == errSecSuccess
    }

    public nonisolated func loadSymmetricKey(account: String) -> SymmetricKey? {
        if Self.useInMemoryKeychain {
            let memKey = "SkyBridge.SymmetricKey" + "|" + account
            Self.inMemoryLock.lock()
            let data = Self.inMemoryStore[memKey]
            Self.inMemoryLock.unlock()
            return data.map { SymmetricKey(data: $0) }
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "SkyBridge.SymmetricKey",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { logger.error("对称密钥读取失败: \(status)") }
            return nil
        }
        return SymmetricKey(data: data)
    }

 // MARK: - Secure Enclave P256 签名密钥对

    public nonisolated func generateSecureEnclaveSigningKey(tag: String) -> SecureEnclave.P256.Signing.PrivateKey? {
        do {
            let privateKey = try SecureEnclave.P256.Signing.PrivateKey(compactRepresentable: true)
            let pubData = privateKey.publicKey.rawRepresentation
            _ = storeKeyData(pubData, service: "SkyBridge.SecureEnclavePub", account: tag)
            return privateKey
        } catch {
            logger.error("Secure Enclave 密钥生成失败: \(error.localizedDescription)")
            return nil
        }
    }

    public nonisolated func loadSecureEnclavePublicKey(tag: String) -> P256.Signing.PublicKey? {
        guard let data = loadKeyData(service: "SkyBridge.SecureEnclavePub", account: tag) else { return nil }
        return try? P256.Signing.PublicKey(rawRepresentation: data)
    }

    public nonisolated func storeEnclaveKeyReference(tag: Data, secKey: SecKey) -> Bool {
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueRef as String: secKey
        ]
        SecItemDelete(addQuery as CFDictionary)
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess { logger.error("Enclave Key 引用存储失败: \(status)") }
        return status == errSecSuccess
    }

    public nonisolated func loadEnclaveKeyReference(tag: Data) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let anyItem = item, CFGetTypeID(anyItem) == SecKeyGetTypeID() else {
            return nil
        }
        let secKey = unsafeDowncast(anyItem, to: SecKey.self)
        return secKey
    }

 // MARK: - 非SE P256 签名密钥对（回退）

    public nonisolated func generateP256SigningKeypair(tag: String) -> (private: P256.Signing.PrivateKey, public: P256.Signing.PublicKey)? {
        let priv = P256.Signing.PrivateKey()
        let pub = priv.publicKey
        let privData = priv.rawRepresentation
        let pubData = pub.rawRepresentation
        let ok1 = storeKeyData(privData, service: "SkyBridge.P256Priv", account: tag)
        let ok2 = storeKeyData(pubData, service: "SkyBridge.P256Pub", account: tag)
        if !ok1 || !ok2 { logger.error("P256 密钥对存储失败") }
        return (priv, pub)
    }

    public nonisolated func loadP256PrivateKey(tag: String) -> P256.Signing.PrivateKey? {
        guard let data = loadKeyData(service: "SkyBridge.P256Priv", account: tag) else { return nil }
        return try? P256.Signing.PrivateKey(rawRepresentation: data)
    }

    public nonisolated func loadP256PublicKey(tag: String) -> P256.Signing.PublicKey? {
        guard let data = loadKeyData(service: "SkyBridge.P256Pub", account: tag) else { return nil }
        return try? P256.Signing.PublicKey(rawRepresentation: data)
    }

 // MARK: - 导入/导出
 // 保留上方显式 SecItemAdd/SecItemCopyMatching 实现，避免重复定义

 // MARK: - 底层Keychain封装

 /// 底层 Keychain 写入（nonisolated - Keychain API 线程安全）
    private nonisolated func storeKeyData(_ data: Data, service: String, account: String) -> Bool {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return true
        }
 // 若已存在且内容一致，避免重复写入，减少冗余项
        if let existing = loadKeyData(service: service, account: account), existing == data { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data
        ]
        SecItemDelete(query as CFDictionary)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess { logger.error("Keychain 写入失败: \(status)") }
        return status == errSecSuccess
    }

 /// 底层 Keychain 读取（nonisolated - Keychain API 线程安全）
    private nonisolated func loadKeyData(service: String, account: String) -> Data? {
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
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return data
    }

 // MARK: - Keychain 去重与清理

 /// 根据 service 前缀扫描并清理重复项（同一 account 下保留最新一条）
 ///
 /// nonisolated - Keychain 扫描和删除操作是系统级线程安全的
    public nonisolated func deduplicate(servicePrefix: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true
        ]
        var itemsRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &itemsRef)
        guard status == errSecSuccess, let items = itemsRef as? [[String: Any]] else { return }
 // 分组并清理
        var grouped: [String: [(attrs: [String: Any], data: Data)]] = [:]
        for it in items {
            guard let svc = it[kSecAttrService as String] as? String, svc.hasPrefix(servicePrefix),
                  let acc = it[kSecAttrAccount as String] as? String,
                  let data = it[kSecValueData as String] as? Data else { continue }
            grouped[svc + "|" + acc, default: []].append((it, data))
        }
        for (_, arr) in grouped where arr.count > 1 {
 // 保留第一条，删除其他重复项
            for dup in arr.dropFirst() {
                let del: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: dup.attrs[kSecAttrService as String] as? String ?? "",
                    kSecAttrAccount as String: dup.attrs[kSecAttrAccount as String] as? String ?? ""
                ]
                SecItemDelete(del as CFDictionary)
            }
        }
 // 注意：nonisolated 方法不能访问 actor-isolated 的 logger
 // 日志已移除以符合 Swift 6.2.1 严格并发
    }
}

// ML-DSA/ML-KEM Keychain存取接口将在升级到最新SDK后补充具体类型
// MARK: - 通用API密钥与服务配置
@available(macOS 14.0, *)
extension KeychainManager {
    public struct SupabaseConfig: Codable { public let url: String; public let anonKey: String; public let serviceRoleKey: String? }
    public struct NebulaConfig: Codable { public let clientId: String; public let clientSecret: String }
    public struct SMSConfig: Codable { public let accessKeyId: String; public let accessKeySecret: String }

    public nonisolated func storeWeatherAPIKey(_ key: String) throws {
        let ok = storeKeyData(Data(key.utf8), service: "SkyBridge.Weather", account: "OpenWeatherMap")
        if !ok { throw NSError(domain: "Keychain", code: -1) }
    }

    public nonisolated func retrieveWeatherAPIKey() throws -> String {
        guard let data = loadKeyData(service: "SkyBridge.Weather", account: "OpenWeatherMap"), let str = String(data: data, encoding: .utf8) else { throw NSError(domain: "Keychain", code: -2) }
        return str
    }

    public nonisolated func storeAppleUserID(_ userID: String) throws {
        let trimmed = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw NSError(domain: "Keychain", code: -20) }
        let ok = storeKeyData(Data(trimmed.utf8), service: "SkyBridge.Auth", account: "AppleUserID")
        if !ok { throw NSError(domain: "Keychain", code: -21) }
    }

    public nonisolated func retrieveAppleUserID() -> String? {
        guard let data = loadKeyData(service: "SkyBridge.Auth", account: "AppleUserID"),
              let str = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public nonisolated func deleteAppleUserID() {
        if Self.useInMemoryKeychain {
            let key = "SkyBridge.Auth" + "|" + "AppleUserID"
            Self.inMemoryLock.lock()
            Self.inMemoryStore.removeValue(forKey: key)
            Self.inMemoryLock.unlock()
            return
        }
        let del: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "SkyBridge.Auth",
            kSecAttrAccount as String: "AppleUserID"
        ]
        SecItemDelete(del as CFDictionary)
    }

    public nonisolated func storeSupabaseConfig(url: String, anonKey: String, serviceRoleKey: String?) throws {
        let base = "SkyBridge.Supabase"
        let ok1 = storeKeyData(Data(url.utf8), service: base, account: "URL")
        let ok2 = storeKeyData(Data(anonKey.utf8), service: base, account: "AnonKey")
        let ok3 = serviceRoleKey.map { storeKeyData(Data($0.utf8), service: base, account: "ServiceRoleKey") } ?? true
        if !ok1 || !ok2 || !ok3 { throw NSError(domain: "Keychain", code: -3) }
    }

    public nonisolated func retrieveSupabaseConfig() throws -> SupabaseConfig {
        let base = "SkyBridge.Supabase"
        guard let url = loadKeyData(service: base, account: "URL").flatMap({ String(data: $0, encoding: .utf8) }),
              let anon = loadKeyData(service: base, account: "AnonKey").flatMap({ String(data: $0, encoding: .utf8) }) else { throw NSError(domain: "Keychain", code: -6) }
        let sRole = loadKeyData(service: base, account: "ServiceRoleKey").flatMap({ String(data: $0, encoding: .utf8) })
        return SupabaseConfig(url: url, anonKey: anon, serviceRoleKey: sRole)
    }

    public nonisolated func storeNebulaConfig(clientId: String, clientSecret: String) throws {
        let base = "SkyBridge.Nebula"
        let ok1 = storeKeyData(Data(clientId.utf8), service: base, account: "ClientId")
        let ok2 = storeKeyData(Data(clientSecret.utf8), service: base, account: "ClientSecret")
        if !ok1 || !ok2 { throw NSError(domain: "Keychain", code: -4) }
    }

    public nonisolated func retrieveNebulaConfig() throws -> NebulaConfig {
        let base = "SkyBridge.Nebula"
        guard let cid = loadKeyData(service: base, account: "ClientId").flatMap({ String(data: $0, encoding: .utf8) }),
              let csec = loadKeyData(service: base, account: "ClientSecret").flatMap({ String(data: $0, encoding: .utf8) }) else { throw NSError(domain: "Keychain", code: -7) }
        return NebulaConfig(clientId: cid, clientSecret: csec)
    }

    public nonisolated func storeSMSConfig(accessKeyId: String, accessKeySecret: String) throws {
        let base = "SkyBridge.SMS"
        let ok1 = storeKeyData(Data(accessKeyId.utf8), service: base, account: "AccessKeyId")
        let ok2 = storeKeyData(Data(accessKeySecret.utf8), service: base, account: "AccessKeySecret")
        if !ok1 || !ok2 { throw NSError(domain: "Keychain", code: -5) }
    }

    public nonisolated func retrieveSMSConfig() throws -> SMSConfig {
        let base = "SkyBridge.SMS"
        guard let akid = loadKeyData(service: base, account: "AccessKeyId").flatMap({ String(data: $0, encoding: .utf8) }),
              let aksec = loadKeyData(service: base, account: "AccessKeySecret").flatMap({ String(data: $0, encoding: .utf8) }) else { throw NSError(domain: "Keychain", code: -8) }
        return SMSConfig(accessKeyId: akid, accessKeySecret: aksec)
    }

    public nonisolated func deleteAPIKey(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw NSError(domain: "Keychain", code: Int(status)) }
    }
}
@available(macOS 14.0, *)
extension KeychainManager {
 // MARK: - 对端签名公钥持久化（P256.Signing.PublicKey 原始表示）

 /// 将对端签名公钥以原始字节存入钥匙串，按 peerId 区分
    public nonisolated func storePeerSigningPublicKey(_ keyData: Data, peerId: String) -> Bool {
        let ok = storeKeyData(keyData, service: "SkyBridge.PeerSigningPub", account: peerId)
        if !ok { logger.error("对端签名公钥存储失败: \(peerId)") }
        return ok
    }

 /// 读取指定 peerId 的对端签名公钥原始字节
    public nonisolated func retrievePeerSigningPublicKey(_ peerId: String) -> Data? {
        return loadKeyData(service: "SkyBridge.PeerSigningPub", account: peerId)
    }

 // MARK: - 设备标识管理

 /// 获取或生成持久化设备 ID (UUID)
 /// 优先从 Keychain 读取，不存在则生成并保存
    public nonisolated func getOrGenerateDeviceId() -> String {
        let service = "SkyBridge.Identity"
        let account = "DeviceUUID"

        if let data = loadKeyData(service: service, account: account),
           let uuidString = String(data: data, encoding: .utf8) {
            return uuidString
        }

        let newUUID = UUID().uuidString
        if let data = newUUID.data(using: .utf8) {
            _ = storeKeyData(data, service: service, account: account)
        }
        return newUUID
    }
}
