import Foundation
import CryptoKit

/// SupabaseService（与 macOS 端同构的 REST 方案）
@MainActor
public final class SupabaseService: ObservableObject {
    public enum RegistrationIdentifierType: String, Sendable {
        case email
        case phone
        case username
    }

    public enum RegistrationAttemptType: String, Sendable {
        case register = "register"
        case verifyCode = "verify_code"
        case login = "login"
    }

    public struct RegistrationGuardDecision: Sendable, Equatable {
        public let allowed: Bool
        public let requiresCaptcha: Bool
        public let reason: String?
        public let retryAfter: Int?
        public let auditTicket: String?

        public init(
            allowed: Bool,
            requiresCaptcha: Bool,
            reason: String?,
            retryAfter: Int?,
            auditTicket: String? = nil
        ) {
            self.allowed = allowed
            self.requiresCaptcha = requiresCaptcha
            self.reason = reason
            self.retryAfter = retryAfter
            self.auditTicket = auditTicket
        }
    }

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

        fileprivate static func logResolvedConfiguration(source: String) {
            SkyBridgeLogger.shared.info("🔐 Supabase 配置来源=\(source) urlValidated=1 anonKeyPresent=1")
        }

        /// 返回不涉及 Keychain I/O 的 Bundle 配置。
        public static func fromEnvironment(logIfMissing: Bool = true) -> Configuration? {
            // 1) Info.plist（Xcode 工程 / App target）
            let dict = Bundle.main.infoDictionary ?? [:]
            if let urlString = dict["SUPABASE_URL"] as? String,
               let url = URL(string: urlString),
               let anonKey = dict["SUPABASE_ANON_KEY"] as? String,
               isValidSupabaseURL(url),
               !anonKey.isEmpty,
               !isPlaceholderConfig(urlString: urlString, anonKey: anonKey) {
                logResolvedConfiguration(source: "Info.plist")
                return Configuration(url: url, anonKey: anonKey)
            }

            // 2) App Bundle Resources：SupabaseConfig.plist（与 macOS 端一致的资源配置方式）
            if let url = Bundle.main.url(forResource: "SupabaseConfig", withExtension: "plist"),
               let dict = NSDictionary(contentsOf: url) as? [String: Any],
               let urlString = dict["SUPABASE_URL"] as? String,
               let baseURL = URL(string: urlString),
               let anonKey = dict["SUPABASE_ANON_KEY"] as? String,
               isValidSupabaseURL(baseURL),
               !anonKey.isEmpty,
               !isPlaceholderConfig(urlString: urlString, anonKey: anonKey) {
                logResolvedConfiguration(source: "SupabaseConfig.plist")
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
                logResolvedConfiguration(source: "Bundle.module")
                return Configuration(url: baseURL, anonKey: anonKey)
            }
#endif

            if logIfMissing {
                SkyBridgeLogger.shared.warning("⚠️ Supabase 未配置（Info.plist/Bundle 未找到有效配置）")
            }
            return nil
        }
    }

    public enum SupabaseError: LocalizedError {
        case configurationMissing
        case configurationStorageUnavailable(String)
        case invalidStoredConfiguration
        case invalidResponse
        case httpStatus(code: Int, message: String?)
        case schemaMismatch(String)
        case network(Error)

        public var errorDescription: String? {
            switch self {
            case .configurationMissing: return "Supabase 配置缺失（SUPABASE_URL / SUPABASE_ANON_KEY）"
            case .configurationStorageUnavailable(let message): return "Supabase Keychain 配置读取失败：\(message)"
            case .invalidStoredConfiguration: return "Supabase Keychain 配置无效"
            case .invalidResponse: return "服务器返回无效响应"
            case .httpStatus(let code, let message): return "HTTP \(code) \(message ?? "")"
            case .schemaMismatch(let message): return "Supabase 认证风控或数据结构未就绪：\(message)"
            case .network(let error): return "网络错误：\(error.localizedDescription)"
            }
        }
    }

    public static func userMessage(for error: Error) -> String? {
        guard let supabaseError = error as? SupabaseError else { return nil }
        switch supabaseError {
        case .configurationMissing:
            return "Supabase 配置缺失，请先在设置中完成配置"
        case .configurationStorageUnavailable:
            return "无法读取 Supabase 安全配置，请检查设备 Keychain 状态"
        case .invalidStoredConfiguration:
            return "Supabase 安全配置无效，请在设置中重新保存"
        case .invalidResponse:
            return "服务器返回无效响应"
        case .httpStatus(let code, let message):
            switch code {
            case 401:
                return "会话过期，请重新登录"
            case 403:
                return "权限不足或会话无效"
            case 429:
                return "请求过于频繁，请稍后重试"
            default:
                if code >= 500 {
                    return "服务器暂时不可用，请稍后重试"
                }
                return message?.isEmpty == false ? message : "服务器返回 HTTP \(code)"
            }
        case .schemaMismatch(let message):
            return "认证风控服务未就绪：\(message)"
        case .network(let error):
            return "网络错误：\(error.localizedDescription)"
        }
    }

    public static let shared = SupabaseService()

    private let urlSession: URLSession
    private var configuration: Configuration?
    private var configurationResolutionCompleted = false
    private var inFlightRefreshSession: (token: String, id: UUID, task: Task<AuthSession, Error>)?

    private init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: cfg)
        self.configuration = nil
    }

    private func requireConfiguration(logIfMissing: Bool = true) async throws -> Configuration {
        if let cfg = configuration {
            let host = (cfg.url.host ?? "").lowercased()
            if host == "your-project.supabase.co" || Configuration.isPlaceholderConfig(urlString: cfg.url.absoluteString, anonKey: cfg.anonKey) {
                SkyBridgeLogger.shared.warning("⚠️ Supabase 当前配置为占位符(host=\(host))，将清理并重新加载。")
                try await KeychainManager.shared.deleteSupabaseConfig()
                configuration = nil
                configurationResolutionCompleted = false
            } else if Configuration.isValidSupabaseURL(cfg.url), !cfg.anonKey.isEmpty {
                return cfg
            }
        }

        if !configurationResolutionCompleted {
            configuration = try await loadPersistedConfiguration()
                ?? Configuration.fromEnvironment(logIfMissing: logIfMissing)
            configurationResolutionCompleted = true
        }

        guard let cfg = configuration else { throw SupabaseError.configurationMissing }
        if (cfg.url.host ?? "").lowercased() == "your-project.supabase.co" {
            SkyBridgeLogger.shared.error("❌ Supabase 仍为占位符(host=your-project.supabase.co)，已拒绝发起请求。请在设置页填写或提供 SupabaseConfig.plist。")
            throw SupabaseError.configurationMissing
        }
        return cfg
    }

    private func loadPersistedConfiguration() async throws -> Configuration? {
        let stored: KeychainManager.SupabaseConfig
        do {
            stored = try await KeychainManager.shared.retrieveSupabaseConfig()
        } catch KeychainError.itemNotFound {
            return nil
        } catch {
            throw SupabaseError.configurationStorageUnavailable(error.localizedDescription)
        }

        if Configuration.isPlaceholderConfig(urlString: stored.url, anonKey: stored.anonKey) {
            SkyBridgeLogger.shared.warning("⚠️ Supabase Keychain 配置为历史占位符，正在清理并迁移到 Bundle 配置。")
            do {
                try await KeychainManager.shared.deleteSupabaseConfig()
            } catch {
                throw SupabaseError.configurationStorageUnavailable(error.localizedDescription)
            }
            return nil
        }

        guard let url = URL(string: stored.url),
              Configuration.isValidSupabaseURL(url),
              !stored.anonKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SupabaseError.invalidStoredConfiguration
        }

        Configuration.logResolvedConfiguration(source: "Keychain")
        return Configuration(url: url, anonKey: stored.anonKey)
    }

    private func makeAnonymousJSONRequest(url: URL, method: String, configuration: Configuration) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(configuration.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        return request
    }

    nonisolated static func normalizedRegistrationIdentifier(
        _ identifier: String,
        type: RegistrationIdentifierType
    ) -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case .email, .username:
            return trimmed.lowercased()
        case .phone:
            return trimmed.filter { $0.isNumber || $0 == "+" }
        }
    }

    nonisolated static func normalizedRegistrationIdentifierHash(
        _ identifier: String,
        type: RegistrationIdentifierType
    ) -> String {
        let normalized = normalizedRegistrationIdentifier(identifier, type: type)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isMissingRPCError(statusCode: Int, body: String?, rpcName: String) -> Bool {
        guard statusCode == 404 || statusCode == 400 else { return false }
        let normalizedBody = (body ?? "").lowercased()
        return normalizedBody.contains("pgrst202")
            || normalizedBody.contains("42883")
            || normalizedBody.contains("could not find the function")
            || normalizedBody.contains(rpcName.lowercased())
    }

    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
        configurationResolutionCompleted = true
    }

    public func availableConfiguration(logIfMissing: Bool = false) async throws -> Configuration? {
        do {
            return try await requireConfiguration(logIfMissing: logIfMissing)
        } catch SupabaseError.configurationMissing {
            return nil
        }
    }

    public var isConfigured: Bool {
        configuration != nil
    }

    public func isSupabaseAccessToken(_ token: String) -> Bool {
        guard let config = configuration else { return false }
        let expectedIssuer = config.url.appendingPathComponent("auth/v1").absoluteString
        return Self.isAuthenticatedAccessToken(token, expectedIssuer: expectedIssuer)
    }

    /// Classifies only authenticated user JWTs issued by the configured Supabase project.
    /// Exact issuer matching prevents a prefix-confusion value from being treated as local,
    /// while audience and role checks exclude anon/service-role tokens from user-session paths.
    nonisolated static func isAuthenticatedAccessToken(
        _ token: String,
        expectedIssuer: String
    ) -> Bool {
        guard !token.isEmpty,
              token.utf8.count <= 65_536,
              token == token.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return false
        }
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              segments.allSatisfy({ !$0.isEmpty }),
              let claims = decodeJWTClaims(token),
              let issuer = claims["iss"] as? String,
              let issuer = normalizedIssuer(issuer),
              let expectedIssuer = normalizedIssuer(expectedIssuer),
              issuer == expectedIssuer,
              claims["role"] as? String == "authenticated" else {
            return false
        }

        if let audience = claims["aud"] as? String {
            return audience == "authenticated"
        }
        if let audiences = claims["aud"] as? [String] {
            return audiences.contains("authenticated")
        }
        return false
    }

    nonisolated private static func normalizedIssuer(_ rawValue: String) -> String? {
        guard !rawValue.isEmpty,
              rawValue.utf8.count <= 2_048,
              rawValue == rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        var value = rawValue
        while value.hasSuffix("/") {
            value.removeLast()
        }
        return value.isEmpty ? nil : value
    }

    // MARK: - Auth

    public func signInWithApple(
        identityToken: String,
        nonce: String? = nil,
        captchaToken: String? = nil
    ) async throws -> AuthSession {
        let config = try await requireConfiguration()

        let endpoint = config.url.appendingPathComponent("auth/v1/token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        var payload: [String: Any] = [
            "provider": "apple",
            "id_token": identityToken
        ]
        if let nonce = nonce?.trimmingCharacters(in: .whitespacesAndNewlines),
           !nonce.isEmpty {
            payload["nonce"] = nonce
        }
        Self.attachCaptchaToken(captchaToken, to: &payload)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        return try await performAuthRequest(request)
    }

    public func signInWithEmail(email: String, password: String, captchaToken: String? = nil) async throws -> AuthSession {
        let config = try await requireConfiguration()

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
        var payload: [String: Any] = ["email": email, "password": password]
        Self.attachCaptchaToken(captchaToken, to: &payload)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        return try await performAuthRequest(request)
    }

    public func sendPhoneOTP(phone: String, captchaToken: String? = nil) async throws {
        let config = try await requireConfiguration()

        let endpoint = config.url.appendingPathComponent("auth/v1/otp")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        var payload: [String: Any] = ["phone": Self.normalizedPhoneForSupabase(phone)]
        Self.attachCaptchaToken(captchaToken, to: &payload)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw SupabaseError.httpStatus(code: http.statusCode, message: body)
        }
    }

    public func signInWithPhone(phone: String, token: String) async throws -> AuthSession {
        let config = try await requireConfiguration()

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
        let normalizedRefreshToken = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRefreshToken.isEmpty else {
            throw SupabaseError.invalidResponse
        }

        if let current = inFlightRefreshSession,
           current.token == normalizedRefreshToken {
            return try await current.task.value
        }

        let config = try await requireConfiguration()
        let refreshID = UUID()
        let task = Task<AuthSession, Error> { [self] in
            try await performRefreshSessionRequest(
                config: config,
                refreshToken: normalizedRefreshToken
            )
        }
        inFlightRefreshSession = (token: normalizedRefreshToken, id: refreshID, task: task)

        do {
            let session = try await task.value
            clearInFlightRefreshSession(ifMatches: refreshID)
            return session
        } catch {
            clearInFlightRefreshSession(ifMatches: refreshID)
            throw error
        }
    }

    /// 与 macOS 端一致：注册时把 nebula_id 写入 metadata（data）
    public func signUp(
        email: String,
        password: String,
        metadata: [String: Any]? = nil,
        captchaToken: String? = nil
    ) async throws -> AuthSession {
        let config = try await requireConfiguration()

        let endpoint = config.url.appendingPathComponent("auth/v1/signup")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        var payload: [String: Any] = ["email": email, "password": password]
        if let metadata { payload["data"] = metadata }
        Self.attachCaptchaToken(captchaToken, to: &payload)
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

    public func resetPassword(email: String, captchaToken: String? = nil) async throws {
        let config = try await requireConfiguration()
        let endpoint = config.url.appendingPathComponent("auth/v1/recover")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        var payload: [String: Any] = ["email": email]
        Self.attachCaptchaToken(captchaToken, to: &payload)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw SupabaseError.httpStatus(code: http.statusCode, message: String(data: data, encoding: .utf8))
        }
    }

    public func assessRegistrationRisk(
        identifier: String,
        identifierType: RegistrationIdentifierType,
        deviceFingerprint: String,
        attemptType: RegistrationAttemptType = .register,
        configName: String? = nil
    ) async throws -> RegistrationGuardDecision {
        let config = try await requireConfiguration()
        let endpoint = config.url.appendingPathComponent("rest/v1/rpc/guard_registration_attempt_v1")
        let normalizedIdentifier = Self.normalizedRegistrationIdentifier(identifier, type: identifierType)
        let identifierHash = Self.normalizedRegistrationIdentifierHash(identifier, type: identifierType)
        let resolvedConfigName = configName ?? Self.registrationRiskConfigName(for: attemptType)

        do {
            return try await submitRegistrationRiskRequest(
                endpoint: endpoint,
                config: config,
                identifierHash: identifierHash,
                identifierType: identifierType,
                normalizedIdentifier: normalizedIdentifier,
                deviceFingerprint: deviceFingerprint,
                configName: resolvedConfigName,
                attemptType: attemptType,
                includeAttemptType: true
            )
        } catch let error as SupabaseError {
            if case .httpStatus(let code, let message) = error,
               Self.isMissingRPCError(statusCode: code, body: message, rpcName: "guard_registration_attempt_v1") {
                SkyBridgeLogger.shared.info("ℹ️ 注册风控 RPC 仍为旧签名，回退到兼容请求")
                return try await submitRegistrationRiskRequest(
                    endpoint: endpoint,
                    config: config,
                    identifierHash: identifierHash,
                    identifierType: identifierType,
                    normalizedIdentifier: normalizedIdentifier,
                    deviceFingerprint: deviceFingerprint,
                    configName: "default",
                    attemptType: attemptType,
                    includeAttemptType: false
                )
            }
            throw error
        }
    }

    private func submitRegistrationRiskRequest(
        endpoint: URL,
        config: Configuration,
        identifierHash: String,
        identifierType: RegistrationIdentifierType,
        normalizedIdentifier: String,
        deviceFingerprint: String,
        configName: String,
        attemptType: RegistrationAttemptType,
        includeAttemptType: Bool
    ) async throws -> RegistrationGuardDecision {
        var request = makeAnonymousJSONRequest(url: endpoint, method: "POST", configuration: config)
        var payload: [String: Any] = [
            "identifier_hash": identifierHash,
            "identifier_type": identifierType.rawValue,
            "raw_identifier": normalizedIdentifier,
            "device_fingerprint": deviceFingerprint,
            "config_name": configName
        ]

        if includeAttemptType {
            payload["attempt_type"] = attemptType.rawValue
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw SupabaseError.httpStatus(code: http.statusCode, message: body)
        }

        if let rows = try? JSONDecoder().decode([SupabaseRegistrationGuardRow].self, from: data),
           let row = rows.first {
            return row.decision
        }

        if let row = try? JSONDecoder().decode(SupabaseRegistrationGuardRow.self, from: data) {
            return row.decision
        }

        throw SupabaseError.schemaMismatch("注册风控 RPC 返回格式无效")
    }

    private static func registrationRiskConfigName(for attemptType: RegistrationAttemptType) -> String {
        switch attemptType {
        case .register:
            return "default"
        case .verifyCode:
            return "verify_code"
        case .login:
            return "login"
        }
    }

    public func recordRegistrationAttempt(
        identifier: String,
        identifierType: RegistrationIdentifierType,
        deviceFingerprint: String,
        attemptType: RegistrationAttemptType,
        success: Bool,
        failureReason: String? = nil,
        captchaRequired: Bool = false,
        captchaPassed: Bool = false,
        auditTicket: String? = nil,
        metadata: [String: String] = [:]
    ) async {
        let config: Configuration
        do {
            config = try await requireConfiguration(logIfMissing: false)
        } catch {
            SkyBridgeLogger.shared.warning("⚠️ 注册审计配置不可用: \(error.localizedDescription)")
            return
        }

        let endpoint = config.url.appendingPathComponent("rest/v1/rpc/record_registration_attempt_v1")
        let normalizedIdentifier = Self.normalizedRegistrationIdentifier(identifier, type: identifierType)

        var request = makeAnonymousJSONRequest(url: endpoint, method: "POST", configuration: config)
        let payload: [String: Any] = [
            "raw_identifier": normalizedIdentifier,
            "identifier_type": identifierType.rawValue,
            "device_fingerprint": deviceFingerprint,
            "attempt_type": attemptType.rawValue,
            "success": success,
            "failure_reason": failureReason ?? NSNull(),
            "captcha_required": captchaRequired,
            "captcha_passed": captchaPassed,
            "audit_ticket": auditTicket ?? NSNull(),
            "metadata": metadata
        ]
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            SkyBridgeLogger.shared.error("❌ 注册审计请求编码失败: \(error.localizedDescription)")
            return
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            SkyBridgeLogger.shared.warning("⚠️ 注册审计网络请求失败: \(error.localizedDescription)")
            return
        }
        guard let http = response as? HTTPURLResponse else {
            SkyBridgeLogger.shared.error("❌ 注册审计返回了非 HTTP 响应")
            return
        }

        if !(200...299).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8)
            if http.statusCode == 401 ||
                http.statusCode == 403 ||
                Self.isMissingRPCError(statusCode: http.statusCode, body: body, rpcName: "record_registration_attempt_v1") {
                return
            }
            SkyBridgeLogger.shared.warning("⚠️ 注册审计远端写入失败: \(body ?? "unknown")")
        }
    }

    private static func attachCaptchaToken(_ captchaToken: String?, to payload: inout [String: Any]) {
        guard let captchaToken = captchaToken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !captchaToken.isEmpty else {
            return
        }

        payload["gotrue_meta_security"] = [
            "captcha_token": captchaToken
        ]
    }

    public func revokeCurrentSession(accessToken: String, scope: String = "local") async throws {
        let config = try await requireConfiguration()
        guard var components = URLComponents(
            url: config.url.appendingPathComponent("auth/v1/logout"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SupabaseError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "scope", value: scope)]
        guard let endpoint = components.url else {
            throw SupabaseError.invalidResponse
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SupabaseError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw SupabaseError.httpStatus(code: http.statusCode, message: String(data: data, encoding: .utf8))
        }
    }

    private func performRefreshSessionRequest(
        config: Configuration,
        refreshToken: String
    ) async throws -> AuthSession {
        guard var comps = URLComponents(
            url: config.url.appendingPathComponent("auth/v1/token"),
            resolvingAgainstBaseURL: false
        ) else {
            throw SupabaseError.invalidResponse
        }
        comps.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let endpoint = comps.url else { throw SupabaseError.invalidResponse }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["refresh_token": refreshToken]
        )

        return try await performAuthRequest(request)
    }

    private func clearInFlightRefreshSession(ifMatches refreshID: UUID) {
        guard inFlightRefreshSession?.id == refreshID else { return }
        inFlightRefreshSession = nil
    }

    // MARK: - Database (Nebula ID)

    public func saveNebulaIdToDatabase(userId: String, nebulaId: String, accessToken: String?) async throws -> Bool {
        let config = try await requireConfiguration()

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

    internal static func normalizedRemoteAssetURL(_ raw: String?, baseURL: URL) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if let absoluteURL = URL(string: raw), absoluteURL.scheme != nil {
            return absoluteURL.absoluteString
        }

        return URL(string: raw, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    private func fetchProfilesFallback(
        userId: String,
        accessToken: String,
        configuration config: Configuration
    ) async -> RemoteUserProfile? {
        let endpoint = config.url.appendingPathComponent("rest/v1/profiles")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,display_name,avatar_url"),
            URLQueryItem(name: "id", value: "eq.\(userId)"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let requestURL = components.url else {
            return nil
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let rows = try? JSONDecoder().decode([SupabaseProfilesRow].self, from: data),
              let row = rows.first else {
            return nil
        }

        return RemoteUserProfile(
            userId: row.id ?? userId,
            email: nil,
            displayName: row.displayName,
            avatarURL: Self.normalizedRemoteAssetURL(row.avatarURL, baseURL: config.url),
            nebulaId: nil
        )
    }

    private func fetchUserProfilesFallback(
        userId: String,
        accessToken: String,
        configuration config: Configuration
    ) async -> RemoteUserProfile? {
        let endpoint = config.url.appendingPathComponent("rest/v1/user_profiles")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "select", value: "id,email,nebula_id,avatar_url,full_name,custom_user_id"),
            URLQueryItem(name: "id", value: "eq.\(userId)"),
            URLQueryItem(name: "limit", value: "1")
        ]
        guard let requestURL = components.url else {
            return nil
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        guard let (data, response) = try? await urlSession.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let rows = try? JSONDecoder().decode([SupabaseUserProfilesRow].self, from: data),
              let row = rows.first else {
            return nil
        }

        return RemoteUserProfile(
            userId: row.id ?? userId,
            email: row.email,
            displayName: row.fullName ?? row.customUserId,
            avatarURL: Self.normalizedRemoteAssetURL(row.avatarURL, baseURL: config.url),
            nebulaId: row.nebulaId
        )
    }

    /// 获取当前用户资料（优先走 Auth API，结构与 metadata 最一致）
    public func fetchCurrentUserProfile(accessToken: String) async throws -> RemoteUserProfile {
        let config = try await requireConfiguration()

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
        let authProfile = RemoteUserProfile(
            userId: user.id,
            email: user.email,
            displayName: user.userMetadata?.displayName,
            avatarURL: Self.normalizedRemoteAssetURL(
                user.userMetadata?.avatarURL,
                baseURL: config.url
            ),
            nebulaId: user.userMetadata?.nebulaId
        )

        let userProfiles = await fetchUserProfilesFallback(
            userId: user.id,
            accessToken: accessToken,
            configuration: config
        )
        let legacyProfiles = await fetchProfilesFallback(
            userId: user.id,
            accessToken: accessToken,
            configuration: config
        )

        return RemoteUserProfile(
            userId: authProfile.userId,
            email: authProfile.email ?? userProfiles?.email,
            displayName: authProfile.displayName ?? userProfiles?.displayName ?? legacyProfiles?.displayName,
            avatarURL: userProfiles?.avatarURL ?? authProfile.avatarURL ?? legacyProfiles?.avatarURL,
            nebulaId: authProfile.nebulaId
        )
    }

    public func updateCurrentUserMetadata(accessToken: String, metadata: [String: Any]) async throws {
        guard !metadata.isEmpty else { return }

        let config = try await requireConfiguration()
        let endpoint = config.url.appendingPathComponent("auth/v1/user")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["data": metadata])

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SupabaseError.invalidResponse }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw SupabaseError.httpStatus(code: http.statusCode, message: body)
        }
    }

    /// 用于设置页的“连接测试”：验证 URL/Key 是否可用（不依赖已登录）
    public func testConnection() async throws {
        let config = try await requireConfiguration()

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
        let config = try await requireConfiguration()
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
                avatarURL: Self.normalizedRemoteAssetURL(
                    authResponse.user.userMetadata?.avatarURL,
                    baseURL: config.url
                ),
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
        case fullName = "full_name"
        case name
        case avatarURL = "avatar_url"
        case nebulaId = "nebula_id"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.displayName =
            try container.decodeIfPresent(String.self, forKey: .displayName) ??
            container.decodeIfPresent(String.self, forKey: .fullName) ??
            container.decodeIfPresent(String.self, forKey: .name)
        self.avatarURL = try container.decodeIfPresent(String.self, forKey: .avatarURL)
        self.nebulaId = try container.decodeIfPresent(String.self, forKey: .nebulaId)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(displayName, forKey: .displayName)
        try container.encodeIfPresent(avatarURL, forKey: .avatarURL)
        try container.encodeIfPresent(nebulaId, forKey: .nebulaId)
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

private struct SupabaseRegistrationGuardRow: Codable {
    let allowed: Bool
    let requiresCaptcha: Bool
    let reason: String?
    let retryAfter: Int?
    let auditTicket: String?

    enum CodingKeys: String, CodingKey {
        case allowed
        case requiresCaptcha = "requires_captcha"
        case reason
        case retryAfter = "retry_after"
        case auditTicket = "audit_ticket"
    }

    var decision: SupabaseService.RegistrationGuardDecision {
        SupabaseService.RegistrationGuardDecision(
            allowed: allowed,
            requiresCaptcha: requiresCaptcha,
            reason: reason,
            retryAfter: retryAfter,
            auditTicket: auditTicket
        )
    }
}

private struct SupabaseProfilesRow: Codable {
    let id: String?
    let displayName: String?
    let avatarURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarURL = "avatar_url"
    }
}

private struct SupabaseUserProfilesRow: Codable {
    let id: String?
    let email: String?
    let nebulaId: String?
    let avatarURL: String?
    let fullName: String?
    let customUserId: String?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case nebulaId = "nebula_id"
        case avatarURL = "avatar_url"
        case fullName = "full_name"
        case customUserId = "custom_user_id"
    }
}

private func decodeJWTClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    let payload = String(parts[1])
    guard let data = base64URLDecode(payload) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func base64URLDecode(_ input: String) -> Data? {
    var base64 = input
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
        base64.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: base64)
}

