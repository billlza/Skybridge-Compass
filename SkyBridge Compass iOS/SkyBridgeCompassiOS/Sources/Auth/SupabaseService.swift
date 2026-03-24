import Foundation

/// SupabaseService（与 macOS 端同构的 REST 方案）
@MainActor
public final class SupabaseService: ObservableObject {
    public struct Configuration: Sendable {
        public let url: URL
        public let anonKey: String

        public init(url: URL, anonKey: String) {
            self.url = url
            self.anonKey = anonKey
        }

        static func isPlaceholderConfig(urlString: String, anonKey: String) -> Bool {
            let u = urlString.lowercased()
            let k = anonKey.lowercased()
            if u.contains("your-project.supabase.co") { return true }
            if k == "your-anon-key" { return true }
            if k.hasPrefix("sb_publishable_") { return false } // publishable keys are ok
            return false
        }
        
        static func isValidSupabaseURL(_ url: URL) -> Bool {
            // iOS 端不强制要求 host 包含 supabase.co（支持 Supabase 自定义域名/代理域名）。
            // 仅要求使用 https 且 host 非空。
            guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
            guard let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !host.isEmpty else { return false }
            return true
        }

        /// iOS 端优先 Keychain，其次 Info.plist
        public static func fromEnvironment(logIfMissing: Bool = true) -> Configuration? {
            // 1) Keychain
            if let keychainConfig = try? KeychainManager.shared.retrieveSupabaseConfig() {
                // If Keychain contains a placeholder config from earlier dev runs, delete it so it won't override bundle config.
                if isPlaceholderConfig(urlString: keychainConfig.url, anonKey: keychainConfig.anonKey) {
                    SkyBridgeLogger.shared.warning("⚠️ Supabase Keychain 配置为占位符，已自动清理（将回退到 Bundle 配置/Info.plist）。")
                    KeychainManager.shared.deleteSupabaseConfig()
                } else if let url = URL(string: keychainConfig.url) {
                    if isValidSupabaseURL(url), !keychainConfig.anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        SkyBridgeLogger.shared.info("🔐 Supabase 配置来源=Keychain host=\(url.host ?? "unknown")")
                        return Configuration(url: url, anonKey: keychainConfig.anonKey)
                    } else {
                        let host = url.host ?? "unknown"
                        let anonEmpty = keychainConfig.anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1" : "0"
                        SkyBridgeLogger.shared.warning("⚠️ Supabase Keychain 配置无效（host=\(host), anonKeyEmpty=\(anonEmpty)），将回退到 Info.plist/Bundle。")
                    }
                } else {
                    SkyBridgeLogger.shared.warning("⚠️ Supabase Keychain 配置无效（URL 无法解析），将回退到 Info.plist/Bundle。")
                }
            }

            // 2) Info.plist（Xcode 工程 / App target）
            let dict = Bundle.main.infoDictionary ?? [:]
            if let urlString = dict["SUPABASE_URL"] as? String,
               let url = URL(string: urlString),
               let anonKey = dict["SUPABASE_ANON_KEY"] as? String,
               isValidSupabaseURL(url),
               !anonKey.isEmpty,
               !isPlaceholderConfig(urlString: urlString, anonKey: anonKey) {
                SkyBridgeLogger.shared.info("🔐 Supabase 配置来源=Info.plist host=\(url.host ?? "unknown")")
                return Configuration(url: url, anonKey: anonKey)
            }

            // 3) App Bundle Resources：SupabaseConfig.plist（与 macOS 端一致的资源配置方式）
            if let url = Bundle.main.url(forResource: "SupabaseConfig", withExtension: "plist"),
               let dict = NSDictionary(contentsOf: url) as? [String: Any],
               let urlString = dict["SUPABASE_URL"] as? String,
               let baseURL = URL(string: urlString),
               let anonKey = dict["SUPABASE_ANON_KEY"] as? String,
               isValidSupabaseURL(baseURL),
               !anonKey.isEmpty,
               !isPlaceholderConfig(urlString: urlString, anonKey: anonKey) {
                SkyBridgeLogger.shared.info("🔐 Supabase 配置来源=SupabaseConfig.plist(host=\(baseURL.host ?? "unknown"))")
                return Configuration(url: baseURL, anonKey: anonKey)
            }

            // 3) Swift Package Resources（打开 Package.swift 运行时的兜底）
#if SWIFT_PACKAGE
            if let url = Bundle.module.url(forResource: "SupabaseConfig", withExtension: "plist"),
               let dict = NSDictionary(contentsOf: url) as? [String: Any],
               let urlString = dict["SUPABASE_URL"] as? String,
               let baseURL = URL(string: urlString),
               let anonKey = dict["SUPABASE_ANON_KEY"] as? String,
               isValidSupabaseURL(baseURL),
               !anonKey.isEmpty,
               !isPlaceholderConfig(urlString: urlString, anonKey: anonKey) {
                SkyBridgeLogger.shared.info("🔐 Supabase 配置来源=Bundle.module(host=\(baseURL.host ?? "unknown"))")
                return Configuration(url: baseURL, anonKey: anonKey)
            }
#endif

            if logIfMissing {
                SkyBridgeLogger.shared.warning("⚠️ Supabase 未配置（Keychain/Info.plist/Bundle 都未找到有效配置）")
            }
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
        self.configuration = Configuration.fromEnvironment(logIfMissing: false)
    }

    private func requireConfiguration() throws -> Configuration {
        // If we have a cached config, validate it; otherwise re-load.
        if let cfg = configuration {
            let host = (cfg.url.host ?? "").lowercased()
            if host == "your-project.supabase.co" || Configuration.isPlaceholderConfig(urlString: cfg.url.absoluteString, anonKey: cfg.anonKey) {
                // Extra-hardening: if an old build ever persisted a placeholder in Keychain, wipe it and reload.
                SkyBridgeLogger.shared.warning("⚠️ Supabase 当前配置为占位符(host=\(host))，将清理并重新加载。")
                KeychainManager.shared.deleteSupabaseConfig()
                configuration = nil
            } else if Configuration.isValidSupabaseURL(cfg.url), !cfg.anonKey.isEmpty {
                return cfg
            }
        }
        configuration = Configuration.fromEnvironment()
        guard let cfg = configuration else { throw SupabaseError.configurationMissing }
        // Final safety: never allow placeholder host to leak into requests.
        if (cfg.url.host ?? "").lowercased() == "your-project.supabase.co" {
            SkyBridgeLogger.shared.error("❌ Supabase 仍为占位符(host=your-project.supabase.co)，已拒绝发起请求。请在设置页填写或提供 SupabaseConfig.plist。")
            throw SupabaseError.configurationMissing
        }
        return cfg
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

    public var isConfigured: Bool {
        configuration != nil
    }

    // MARK: - Auth

    public func signInWithEmail(email: String, password: String) async throws -> AuthSession {
        let config = try requireConfiguration()

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

    public func sendPhoneOTP(phone: String) async throws {
        let config = try requireConfiguration()

        let endpoint = config.url.appendingPathComponent("auth/v1/otp")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["phone": Self.normalizedPhoneForSupabase(phone)]
        )

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw SupabaseError.httpStatus(code: http.statusCode, message: body)
        }
    }

    public func signInWithPhone(phone: String, token: String) async throws -> AuthSession {
        let config = try requireConfiguration()

        let endpoint = config.url.appendingPathComponent("auth/v1/token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: [
                "phone": Self.normalizedPhoneForSupabase(phone),
                "token": token,
                "type": "sms",
                "grant_type": "otp"
            ]
        )

        return try await performAuthRequest(request)
    }

    /// 刷新 access token（当 JWT 过期 / bad_jwt 时使用）
    public func refreshSession(refreshToken: String) async throws -> AuthSession {
        let config = try requireConfiguration()

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
        let config = try requireConfiguration()

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
        let config = try requireConfiguration()
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
        let config = try requireConfiguration()

        let endpoint = config.url.appendingPathComponent("rest/v1/users")
        var comps = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "id", value: "eq.\(userId)")]
        guard let url = comps?.url else { throw SupabaseError.invalidResponse }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")

        // SECURITY: Never use service-role key from a client app. Also avoid anon-key writes to PostgREST.
        // Only allow authenticated user JWT.
        guard let token = accessToken, token != "pending_verification", !token.isEmpty else {
            return false
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

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
        let config = try requireConfiguration()

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
        let config = try requireConfiguration()

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
                displayName: authResponse.user.userMetadata?.displayName ?? (authResponse.user.phone ?? authResponse.user.email ?? "用户"),
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

    private static func normalizedPhoneForSupabase(_ rawPhone: String) -> String {
        let sanitized = rawPhone.filter { $0.isNumber || $0 == "+" }
        if sanitized.hasPrefix("+") {
            return sanitized
        }
        if sanitized.hasPrefix("86"), sanitized.count == 13 {
            return "+\(sanitized)"
        }
        if sanitized.count == 11, sanitized.hasPrefix("1") {
            return "+86\(sanitized)"
        }
        return sanitized
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
    let phone: String?
    let userMetadata: SupabaseUserMetadata?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case phone
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

