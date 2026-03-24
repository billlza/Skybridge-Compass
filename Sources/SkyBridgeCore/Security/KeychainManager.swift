import Foundation
import Security
import CryptoKit
import LocalAuthentication
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

    private var interactiveUnlockCompleted = false
    private var lastInteractiveUnlockFailureAt: Date = .distantPast
    private let interactiveUnlockCooldown: TimeInterval = 12 * 60 * 60

    private init() {}

    private nonisolated static var useInMemoryKeychain: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        return NSClassFromString("XCTestCase") != nil
    }
    private nonisolated(unsafe) static var inMemoryStore: [String: Data] = [:]
    private nonisolated static let inMemoryLock = NSLock()

    private nonisolated func makeNonInteractiveAuthContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }

    private nonisolated static func performInteractiveUnlockProbe() -> OSStatus {
        let context = LAContext()
        context.interactionNotAllowed = false
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item)
    }

    /// 启动时调用：最多触发一次交互式解锁，后续全部静默读取。
    public func prepareInteractiveUnlockIfNeeded() async -> Bool {
        if Self.useInMemoryKeychain { return true }
        if interactiveUnlockCompleted { return true }

        let now = Date()
        if now.timeIntervalSince(lastInteractiveUnlockFailureAt) < interactiveUnlockCooldown {
            logger.info("跳过交互式 Keychain 解锁（冷却中）")
            return false
        }

        let status = Self.performInteractiveUnlockProbe()
        switch status {
        case errSecSuccess, errSecItemNotFound:
            interactiveUnlockCompleted = true
            logger.info("Keychain 交互式解锁准备完成")
            return true
        default:
            lastInteractiveUnlockFailureAt = now
            logger.error("Keychain 交互式解锁失败: \(status)")
            return false
        }
    }

    private nonisolated func upsertGenericPassword(
        service: String,
        account: String,
        data: Data,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> OSStatus {
        let context = makeNonInteractiveAuthContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseAuthenticationContext as String: context,
        ]
        let updateAttrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessibility
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return errSecSuccess }
        if updateStatus != errSecItemNotFound { return updateStatus }

        var addQuery = query
        addQuery.removeValue(forKey: kSecUseAuthenticationContext as String)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = accessibility
        return SecItemAdd(addQuery as CFDictionary, nil)
    }

 // MARK: - Keychain 基础操作（nonisolated - Keychain 本身线程安全）

    public nonisolated func importKey(
        data: Data,
        service: String,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> Bool {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return true
        }
        let status = upsertGenericPassword(
            service: service,
            account: account,
            data: data,
            accessibility: accessibility
        )
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
        let context = makeNonInteractiveAuthContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
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
        let status = upsertGenericPassword(
            service: "SkyBridge.SymmetricKey",
            account: account,
            data: data,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
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
        let context = makeNonInteractiveAuthContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "SkyBridge.SymmetricKey",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
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
        let ok1 = storeKeyData(
            privData,
            service: "SkyBridge.P256Priv",
            account: tag,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        let ok2 = storeKeyData(
            pubData,
            service: "SkyBridge.P256Pub",
            account: tag,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
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
    private nonisolated func storeKeyData(
        _ data: Data,
        service: String,
        account: String,
        accessibility: CFString = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    ) -> Bool {
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore[key] = data
            Self.inMemoryLock.unlock()
            return true
        }
 // 若已存在且内容一致，避免重复写入，减少冗余项
        if let existing = loadKeyData(service: service, account: account), existing == data { return true }
        let status = upsertGenericPassword(
            service: service,
            account: account,
            data: data,
            accessibility: accessibility
        )
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
        let context = makeNonInteractiveAuthContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context,
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
        guard !servicePrefix.isEmpty else { return }
        if Self.useInMemoryKeychain { return }

        let context = makeNonInteractiveAuthContext()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnPersistentRef as String: true,
            kSecUseAuthenticationContext as String: context,
        ]
        var itemsRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &itemsRef)
        guard status == errSecSuccess, let items = itemsRef as? [[String: Any]] else { return }
 // 分组并清理
        var grouped: [String: [[String: Any]]] = [:]
        for it in items {
            guard let svc = it[kSecAttrService as String] as? String, svc.hasPrefix(servicePrefix),
                  let acc = it[kSecAttrAccount as String] as? String else { continue }
            grouped[svc + "|" + acc, default: []].append(it)
        }
        for (_, arr) in grouped where arr.count > 1 {
 // 保留最近修改的一条，删除其余重复项（按 persistent ref 精确删除，避免误删全部）
            let sorted = arr.sorted { lhs, rhs in
                let lhsDate = (lhs[kSecAttrModificationDate as String] as? Date) ?? (lhs[kSecAttrCreationDate as String] as? Date) ?? .distantPast
                let rhsDate = (rhs[kSecAttrModificationDate as String] as? Date) ?? (rhs[kSecAttrCreationDate as String] as? Date) ?? .distantPast
                return lhsDate > rhsDate
            }
            for dup in sorted.dropFirst() {
                guard let persistentRef = dup[kSecValuePersistentRef as String] as? Data else { continue }
                let del: [String: Any] = [kSecValuePersistentRef as String: persistentRef]
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
    public struct SupabaseConfig: Codable {
        public let url: String
        public let anonKey: String

        public init(url: String, anonKey: String) {
            self.url = url
            self.anonKey = anonKey
        }

        @available(*, deprecated, message: "Client-side Supabase configuration no longer exposes service role keys.")
        public var serviceRoleKey: String? {
            nil
        }
    }
    public struct NebulaConfig: Codable {
        public let baseURL: String
        public let clientId: String
        public let clientSecret: String?
    }
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
        let context = makeNonInteractiveAuthContext()
        let del: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "SkyBridge.Auth",
            kSecAttrAccount as String: "AppleUserID",
            kSecUseAuthenticationContext as String: context,
        ]
        SecItemDelete(del as CFDictionary)
    }

    public nonisolated func storeSupabaseConfig(url: String, anonKey: String) throws {
        let base = "SkyBridge.Supabase"
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAnonKey = anonKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let parsedURL = URL(string: trimmedURL),
              let scheme = parsedURL.scheme?.lowercased(),
              ["https", "http"].contains(scheme),
              parsedURL.host != nil else {
            throw NSError(
                domain: "Keychain",
                code: -30,
                userInfo: [NSLocalizedDescriptionKey: "Supabase URL 无效"]
            )
        }
        guard !trimmedAnonKey.isEmpty else {
            throw NSError(
                domain: "Keychain",
                code: -31,
                userInfo: [NSLocalizedDescriptionKey: "Supabase 匿名密钥不能为空"]
            )
        }

        let ok1 = storeKeyData(Data(trimmedURL.utf8), service: base, account: "URL")
        let ok2 = storeKeyData(Data(trimmedAnonKey.utf8), service: base, account: "AnonKey")
        try purgeLegacySupabaseServiceRoleKey()
        if !ok1 || !ok2 { throw NSError(domain: "Keychain", code: -3) }
    }

    @available(*, deprecated, message: "Supabase service role keys must remain server-side.")
    public nonisolated func storeSupabaseConfig(url: String, anonKey: String, serviceRoleKey: String?) throws {
        try storeSupabaseConfig(url: url, anonKey: anonKey)
    }

    public nonisolated func retrieveSupabaseConfig() throws -> SupabaseConfig {
        let base = "SkyBridge.Supabase"
        guard let url = loadKeyData(service: base, account: "URL").flatMap({ String(data: $0, encoding: .utf8) }),
              let anon = loadKeyData(service: base, account: "AnonKey").flatMap({ String(data: $0, encoding: .utf8) }) else { throw NSError(domain: "Keychain", code: -6) }
        try purgeLegacySupabaseServiceRoleKey()
        return SupabaseConfig(url: url, anonKey: anon)
    }

    public nonisolated func storeNebulaConfig(baseURL: String, clientId: String, clientSecret: String?) throws {
        let base = "SkyBridge.Nebula"
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientId = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedClientSecret = clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)

        let ok1 = storeKeyData(Data(trimmedBaseURL.utf8), service: base, account: "BaseURL")
        let ok2 = storeKeyData(Data(trimmedClientId.utf8), service: base, account: "ClientId")
        let ok3: Bool
        if let trimmedClientSecret, !trimmedClientSecret.isEmpty {
            ok3 = storeKeyData(Data(trimmedClientSecret.utf8), service: base, account: "ClientSecret")
        } else {
            do {
                try deleteAPIKey(service: base, account: "ClientSecret")
                ok3 = true
            } catch {
                ok3 = false
            }
        }
        if !ok1 || !ok2 || !ok3 { throw NSError(domain: "Keychain", code: -4) }
    }

    public nonisolated func retrieveNebulaConfig() throws -> NebulaConfig {
        let base = "SkyBridge.Nebula"
        guard let cid = loadKeyData(service: base, account: "ClientId").flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw NSError(domain: "Keychain", code: -7)
        }

        let baseURL = loadKeyData(service: base, account: "BaseURL")
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let clientSecret = loadKeyData(service: base, account: "ClientSecret")
            .flatMap { String(data: $0, encoding: .utf8) }

        return NebulaConfig(baseURL: baseURL, clientId: cid, clientSecret: clientSecret)
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
        if Self.useInMemoryKeychain {
            let key = service + "|" + account
            Self.inMemoryLock.lock()
            Self.inMemoryStore.removeValue(forKey: key)
            Self.inMemoryLock.unlock()
            return
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound { throw NSError(domain: "Keychain", code: Int(status)) }
    }

    private nonisolated func purgeLegacySupabaseServiceRoleKey() throws {
        try deleteAPIKey(service: "SkyBridge.Supabase", account: "ServiceRoleKey")
    }

    public nonisolated func storeAuthSession(_ session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let status = upsertGenericPassword(
            service: "com.skybridge.compass.authsession",
            account: "primary",
            data: data,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
        if status != errSecSuccess {
            throw NSError(domain: "Keychain", code: Int(status))
        }
    }

    public nonisolated func loadAuthSession() -> AuthSession? {
        guard let data = loadKeyData(
            service: "com.skybridge.compass.authsession",
            account: "primary"
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(AuthSession.self, from: data)
    }

    public nonisolated func deleteAuthSession() {
        try? deleteAPIKey(service: "com.skybridge.compass.authsession", account: "primary")
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
