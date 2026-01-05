import Foundation
import Combine
import Security
import os.log

/// 统一管理租户权限标记的结构体，确保所有功能调用都有明确授权。
public struct TenantPermission: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static let remoteDesktop = TenantPermission(rawValue: 1 << 0)
    public static let fileTransfer = TenantPermission(rawValue: 1 << 1)
    public static let notifications = TenantPermission(rawValue: 1 << 2)
}

public struct TenantDescriptor: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var displayName: String
    public var username: String
    public var domain: String?
    public var permissions: TenantPermission
    public var passwordKey: String

    public init(id: UUID = UUID(),
                displayName: String,
                username: String,
                domain: String?,
                permissions: TenantPermission,
                passwordKey: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.username = username
        self.domain = domain
        self.permissions = permissions
        self.passwordKey = passwordKey ?? id.uuidString
    }
}

public struct TenantCredential: Sendable {
    public let username: String
    public let password: String
    public let domain: String?
}

public enum TenantAccessError: Error, LocalizedError, Sendable {
    case noActiveTenant
    case permissionDenied(TenantPermission, TenantDescriptor)
    case credentialMissing
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .noActiveTenant:
            return "当前未激活任何租户，请先选择或创建租户"
        case .permissionDenied(let permission, let tenant):
            return "租户 \(tenant.displayName) 缺少权限: \(permission.rawValue)"
        case .credentialMissing:
            return "未能在钥匙串中找到租户凭据"
        case .keychain(let status):
            return "钥匙串操作失败，状态码 \(status)"
        }
    }
}

/// 负责租户列表、凭据存储和访问令牌的集中式控制器。
@MainActor
public final class TenantAccessController: Sendable {
    public static let shared = TenantAccessController()

    public var tenantsPublisher: AnyPublisher<[TenantDescriptor], Never> {
        tenantsSubject.eraseToAnyPublisher()
    }

    public var activeTenantPublisher: AnyPublisher<TenantDescriptor?, Never> {
        activeTenantSubject.eraseToAnyPublisher()
    }

    public var activeTenant: TenantDescriptor? {
        activeTenantSubject.value
    }

    private let log = Logger(subsystem: "com.skybridge.compass", category: "Tenant")
    private let storageKey = "com.skybridge.compass.tenants"
    private let activeStorageKey = "com.skybridge.compass.tenants.active"
    private let keychainService = "com.skybridge.compass.tenants"
    private let tenantsSubject = CurrentValueSubject<[TenantDescriptor], Never>([])
    private let activeTenantSubject = CurrentValueSubject<TenantDescriptor?, Never>(nil)
    private let queue = DispatchQueue(label: "com.skybridge.compass.tenants", attributes: .concurrent)
    private var didBootstrap = false
    private var currentSession: AuthSession?

    private init() {}

 /// 绑定认证会话，用于后续API调用的身份验证。
    public func bindAuthentication(session: AuthSession) async {
        currentSession = session
        log.info("Bind authentication session for \(session.userIdentifier)")
    }

 /// 注销时清理访问令牌，避免旧会话被误用。
    public func clearAuthentication() async {
        currentSession = nil
    }

 /// 当前已登录用户的访问令牌。
    public var accessToken: String? {
        currentSession?.accessToken
    }

    public func bootstrap() {
        guard !didBootstrap else { return }
        loadFromDisk()
        didBootstrap = true
    }

    @discardableResult
    public func registerTenant(displayName: String,
                                username: String,
                                password: String,
                                domain: String?,
                                permissions: TenantPermission) async throws -> TenantDescriptor {
        let tenant = TenantDescriptor(displayName: displayName,
                                      username: username,
                                      domain: domain,
                                      permissions: permissions)
        try await storePasswordAsync(password, for: tenant)
        
 // 使用异步操作替代同步队列
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task { @MainActor in
                var existing = self.tenantsSubject.value
                existing.removeAll { $0.id == tenant.id }
                existing.append(tenant)
                
                self.tenantsSubject.send(existing)
                self.persistTenants(existing)
                if self.activeTenantSubject.value == nil {
                    self.activeTenantSubject.send(tenant)
                    self.persistActiveTenant(id: tenant.id)
                }
                continuation.resume()
            }
        }
        
        log.info("Registered tenant \(tenant.displayName)")
        return tenant
    }

    public func setActiveTenant(id: UUID) async throws {
 // 在主线程获取租户描述符
        let tenant = await MainActor.run {
            tenantsSubject.value.first(where: { $0.id == id })
        }
        
        guard let tenant = tenant else {
            throw TenantAccessError.noActiveTenant
        }
        
        await MainActor.run {
            activeTenantSubject.send(tenant)
            persistActiveTenant(id: id)
        }
    }

 /// 检查当前活跃租户是否具有指定权限
    public func requirePermission(_ permission: TenantPermission) async throws -> TenantDescriptor {
 // 在主线程上获取当前活跃租户，避免在Sendable闭包中引用主线程隔离的属性
        guard let tenant = activeTenantSubject.value else {
            throw TenantAccessError.noActiveTenant
        }
        guard tenant.permissions.contains(permission) else {
            throw TenantAccessError.permissionDenied(permission, tenant)
        }
        return tenant
    }

    public func credentials(for tenantID: UUID) async throws -> TenantCredential {
 // 在主线程获取租户描述符
        let descriptor = await MainActor.run {
            tenantsSubject.value.first(where: { $0.id == tenantID })
        }
        
        guard let descriptor = descriptor else {
            throw TenantAccessError.noActiveTenant
        }
        
        let password = try await retrievePasswordAsync(for: descriptor)
        return TenantCredential(username: descriptor.username, password: password, domain: descriptor.domain)
    }

    public func updatePermissions(for tenantID: UUID, permissions: TenantPermission) async {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                var tenants = self.tenantsSubject.value
                guard let index = tenants.firstIndex(where: { $0.id == tenantID }) else { 
                    continuation.resume()
                    return 
                }
                tenants[index].permissions = permissions
                
                self.tenantsSubject.send(tenants)
                self.persistTenants(tenants)
                if let active = self.activeTenantSubject.value, active.id == tenantID {
                    self.activeTenantSubject.send(tenants[index])
                }
                continuation.resume()
            }
        }
    }

    private func loadFromDisk() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: storageKey) {
            do {
                let tenants = try JSONDecoder().decode([TenantDescriptor].self, from: data)
                tenantsSubject.send(tenants)
            } catch {
                log.error("Failed to decode tenants from disk: \(error.localizedDescription)")
                tenantsSubject.send([])
            }
        }

        if let activeIdentifier = defaults.string(forKey: activeStorageKey),
           let uuid = UUID(uuidString: activeIdentifier),
           let tenant = tenantsSubject.value.first(where: { $0.id == uuid }) {
            activeTenantSubject.send(tenant)
        }
    }

    private func persistTenants(_ tenants: [TenantDescriptor]) {
        do {
            let data = try JSONEncoder().encode(tenants)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch {
            log.error("Unable to persist tenants: \(error.localizedDescription)")
        }
    }

    private func persistActiveTenant(id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: activeStorageKey)
    }

    private func storePasswordAsync(_ password: String, for tenant: TenantDescriptor) async throws {
        let passwordData = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tenant.passwordKey
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = passwordData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        
        if status != errSecSuccess {
            throw TenantAccessError.keychain(status)
        }
    }

    private func storePassword(_ password: String, for tenant: TenantDescriptor) throws {
        let passwordData = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tenant.passwordKey
        ]
        SecItemDelete(query as CFDictionary)

        var attributes = query
        attributes[kSecValueData as String] = passwordData
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw TenantAccessError.keychain(status)
        }
    }

    private func retrievePasswordAsync(for tenant: TenantDescriptor) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            Task.detached {
                var query: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: self.keychainService,
                    kSecAttrAccount as String: tenant.passwordKey,
                    kSecReturnData as String: true
                ]
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var item: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &item)
                
                if status == errSecSuccess, 
                   let data = item as? Data, 
                   let password = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: password)
                } else {
                    continuation.resume(throwing: TenantAccessError.credentialMissing)
                }
            }
        }
    }

    private func retrievePassword(for tenant: TenantDescriptor) throws -> String {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: tenant.passwordKey,
            kSecReturnData as String: true
        ]
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw TenantAccessError.credentialMissing
        }
        return password
    }
}
