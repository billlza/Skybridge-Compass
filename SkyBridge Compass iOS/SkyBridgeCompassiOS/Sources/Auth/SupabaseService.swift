import Foundation

/// SupabaseService（与 macOS 端同构的 REST 方案）
@MainActor
public final class SupabaseService: ObservableObject {
    public struct Configuration: Sendable {
        public let url: URL
        public let anonKey: String
        public let serviceRoleKey: String?

        public init(url: URL, anonKey: String, serviceRoleKey: String? = nil) {
            self.url = url
            self.anonKey = anonKey
            self.serviceRoleKey = serviceRoleKey
        }

        /// iOS 端优先 Keychain，其次 Info.plist
        public static func fromEnvironment() -> Configuration? {
            // 1) Keychain
            if let keychainConfig = try? KeychainManager.shared.retrieveSupabaseConfig(),
               let url = URL(string: keychainConfig.url) {
                return Configuration(url: url, anonKey: keychainConfig.anonKey, serviceRoleKey: keychainConfig.serviceRoleKey)
            }

            // 2) Info.plist（Xcode 工程 / App target）
            let dict = Bundle.main.infoDictionary ?? [:]
            if let urlString = dict["SUPABASE_URL"] as? String,
               let url = URL(string: urlString),
               let anonKey = dict["SUPABASE_ANON_KEY"] as? String {
                let serviceRoleKey = dict["SUPABASE_SERVICE_ROLE_KEY"] as? String
                return Configuration(url: url, anonKey: anonKey, serviceRoleKey: serviceRoleKey)
            }

            // 3) App Bundle Resources：SupabaseConfig.plist（与 macOS 端一致的资源配置方式）
            if let url = Bundle.main.url(forResource: "SupabaseConfig", withExtension: "plist"),
               let dict = NSDictionary(contentsOf: url) as? [String: Any],
               let urlString = dict["SUPABASE_URL"] as? String,
               let baseURL = URL(string: urlString),
               let anonKey = dict["SUPABASE_ANON_KEY"] as? String {
                let serviceRoleKey = dict["SUPABASE_SERVICE_ROLE_KEY"] as? String
                return Configuration(url: baseURL, anonKey: anonKey, serviceRoleKey: serviceRoleKey)
            }

            // 3) Swift Package Resources（打开 Package.swift 运行时的兜底）
#if SWIFT_PACKAGE
            if let url = Bundle.module.url(forResource: "SupabaseConfig", withExtension: "plist"),
               let dict = NSDictionary(contentsOf: url) as? [String: Any],
               let urlString = dict["SUPABASE_URL"] as? String,
               let baseURL = URL(string: urlString),
               let anonKey = dict["SUPABASE_ANON_KEY"] as? String {
                let serviceRoleKey = dict["SUPABASE_SERVICE_ROLE_KEY"] as? String
                return Configuration(url: baseURL, anonKey: anonKey, serviceRoleKey: serviceRoleKey)
            }
#endif

            return nil
        }
    }

    public enum SupabaseError: LocalizedError {
        case configurationMissing
        case invalidResponse
        case httpStatus(code: Int, message: String?)
        case network(Error)

        public var errorDescription: String? {
            switch self {
            case .configurationMissing: return "Supabase 配置缺失（SUPABASE_URL / SUPABASE_ANON_KEY）"
            case .invalidResponse: return "服务器返回无效响应"
            case .httpStatus(let code, let message): return "HTTP \(code) \(message ?? "")"
            case .network(let error): return "网络错误：\(error.localizedDescription)"
            }
        }
    }

    public static let shared = SupabaseService()

    private let urlSession: URLSession
    private var configuration: Configuration?

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: cfg)
        self.configuration = Configuration.fromEnvironment()
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    public var isConfigured: Bool {
        configuration != nil
    }

    // MARK: - Auth

    public func signInWithEmail(email: String, password: String) async throws -> AuthSession {
        guard let config = configuration else { throw SupabaseError.configurationMissing }

        guard var comps = URLComponents(url: config.url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false) else {
            throw SupabaseError.invalidResponse
        }
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        guard let endpoint = comps.url else { throw SupabaseError.invalidResponse }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email, "password": password])

        return try await performAuthRequest(request)
    }

    /// 刷新 access token（当 JWT 过期 / bad_jwt 时使用）
    public func refreshSession(refreshToken: String) async throws -> AuthSession {
        guard let config = configuration else { throw SupabaseError.configurationMissing }

        guard var comps = URLComponents(url: config.url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false) else {
            throw SupabaseError.invalidResponse
        }
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let endpoint = comps.url else { throw SupabaseError.invalidResponse }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refresh_token": refreshToken])

        return try await performAuthRequest(request)
    }

    /// 与 macOS 端一致：注册时把 nebula_id 写入 metadata（data）
    public func signUp(email: String, password: String, metadata: [String: Any]? = nil) async throws -> AuthSession {
        guard let config = configuration else { throw SupabaseError.configurationMissing }

        let endpoint = config.url.appendingPathComponent("auth/v1/signup")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        var payload: [String: Any] = ["email": email, "password": password]
        if let metadata { payload["data"] = metadata }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        // macOS 端对 signup 采用特殊解析：可能需要邮箱验证
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw SupabaseError.httpStatus(code: http.statusCode, message: body)
        }

        // 解析 signup response
        if let signUp = try? JSONDecoder().decode(SupabaseSignUpResponse.self, from: data) {
            return AuthSession(
                accessToken: "pending_verification",
                refreshToken: nil,
                userIdentifier: signUp.id,
                displayName: signUp.email ?? "新用户",
                issuedAt: Date()
            )
        }

        // 有些项目会返回标准 token 响应
        if let auth = try? JSONDecoder().decode(SupabaseAuthResponse.self, from: data) {
            return AuthSession(
                accessToken: auth.accessToken,
                refreshToken: auth.refreshToken,
                userIdentifier: auth.user.id,
                displayName: auth.user.email ?? "用户",
                issuedAt: Date()
            )
        }

        throw SupabaseError.invalidResponse
    }

    public func resetPassword(email: String) async throws {
        guard let config = configuration else { throw SupabaseError.configurationMissing }
        let endpoint = config.url.appendingPathComponent("auth/v1/recover")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["email": email])

        let (_, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SupabaseError.invalidResponse
        }
    }

    // MARK: - Database (Nebula ID)

    public func saveNebulaIdToDatabase(userId: String, nebulaId: String, accessToken: String?) async throws -> Bool {
        guard let config = configuration else { throw SupabaseError.configurationMissing }

        let endpoint = config.url.appendingPathComponent("rest/v1/users")
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "id", value: "eq.\(userId)")]
        guard let url = comps?.url else { throw SupabaseError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        if let token = accessToken, token != "pending_verification" {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let serviceKey = config.serviceRoleKey {
            request.setValue("Bearer \(serviceKey)", forHTTPHeaderField: "Authorization")
        } else {
            request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        }

        let updateData: [String: Any] = [
            "nebula_id": nebulaId,
            "updated_at": ISO8601DateFormatter().string(from: Date()),
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: updateData)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }
        if (200...299).contains(http.statusCode) {
            _ = data // keep for debug if needed
            return true
        }
        let body = String(data: data, encoding: .utf8)
        throw SupabaseError.httpStatus(code: http.statusCode, message: body)
    }

    // MARK: - Profile (Auth user)

    public struct RemoteUserProfile: Sendable, Equatable {
        public let userId: String
        public let email: String?
        public let displayName: String?
        public let avatarURL: String?
        public let nebulaId: String?

        public init(userId: String, email: String?, displayName: String?, avatarURL: String?, nebulaId: String?) {
            self.userId = userId
            self.email = email
            self.displayName = displayName
            self.avatarURL = avatarURL
            self.nebulaId = nebulaId
        }
    }

    /// 获取当前用户资料（优先走 Auth API，结构与 metadata 最一致）
    public func fetchCurrentUserProfile(accessToken: String) async throws -> RemoteUserProfile {
        guard let config = configuration else { throw SupabaseError.configurationMissing }

        let endpoint = config.url.appendingPathComponent("auth/v1/user")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw SupabaseError.httpStatus(code: http.statusCode, message: body)
        }

        let user = try JSONDecoder().decode(SupabaseAuthUserResponse.self, from: data)
        return RemoteUserProfile(
            userId: user.id,
            email: user.email,
            displayName: user.userMetadata?.displayName,
            avatarURL: user.userMetadata?.avatarURL,
            nebulaId: user.userMetadata?.nebulaId
        )
    }

    /// 用于设置页的“连接测试”：验证 URL/Key 是否可用（不依赖已登录）
    public func testConnection() async throws {
        guard let config = configuration else { throw SupabaseError.configurationMissing }

        // Supabase GoTrue 健康检查端点
        let endpoint = config.url.appendingPathComponent("auth/v1/health")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw SupabaseError.httpStatus(code: http.statusCode, message: body)
        }
    }

    // MARK: - Helpers

    private func performAuthRequest(_ request: URLRequest) async throws -> AuthSession {
        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8)
                throw SupabaseError.httpStatus(code: http.statusCode, message: body)
            }
            let authResponse = try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
            return AuthSession(
                accessToken: authResponse.accessToken,
                refreshToken: authResponse.refreshToken,
                userIdentifier: authResponse.user.id,
                displayName: authResponse.user.userMetadata?.displayName ?? (authResponse.user.email ?? "用户"),
                email: authResponse.user.email,
                avatarURL: authResponse.user.userMetadata?.avatarURL,
                nebulaId: authResponse.user.userMetadata?.nebulaId,
                issuedAt: Date()
            )
        } catch let err as SupabaseError {
            throw err
        } catch {
            throw SupabaseError.network(error)
        }
    }
}

private struct SupabaseAuthResponse: Codable {
    let accessToken: String
    let refreshToken: String?
    let user: SupabaseUser

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case user
    }
}

private struct SupabaseUser: Codable {
    let id: String
    let email: String?
    let userMetadata: SupabaseUserMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case userMetadata = "user_metadata"
    }
}

private struct SupabaseUserMetadata: Codable {
    let displayName: String?
    let avatarURL: String?
    let nebulaId: String?

    enum CodingKeys: String, CodingKey {
        case displayName = "display_name"
        case avatarURL = "avatar_url"
        case nebulaId = "nebula_id"
    }
}

private struct SupabaseSignUpResponse: Codable {
    let id: String
    let email: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
    }
}

private struct SupabaseAuthUserResponse: Codable {
    let id: String
    let email: String?
    let userMetadata: SupabaseUserMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case userMetadata = "user_metadata"
    }
}

