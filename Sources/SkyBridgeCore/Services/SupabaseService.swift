import Foundation
import Combine
import OSLog

// 由于AuthSession定义在同一个模块中，不需要额外导入
// AuthSession类型在Models.swift中定义，作为public类型可以直接使用

/// Supabase集成服务 - 提供真实的后端API支持
/// 遵循Apple 2025最佳实践，使用async/await和现代Swift特性
@MainActor
public final class SupabaseService: BaseManager {
    
 // MARK: - 配置
    
 /// Supabase项目配置
    public struct Configuration: Sendable {
        public let url: URL
        public let anonKey: String
        
        public init(url: URL, anonKey: String) {
            self.url = url
            self.anonKey = anonKey
        }

        @available(*, deprecated, message: "Supabase service role keys must remain server-side.")
        public init(url: URL, anonKey: String, serviceRoleKey: String? = nil) {
            self.init(url: url, anonKey: anonKey)
        }

        @available(*, deprecated, message: "Client-side Supabase configuration no longer exposes service role keys.")
        public var serviceRoleKey: String? {
            nil
        }
        
 /// 从环境变量或Keychain加载配置
        @MainActor
        public static func fromEnvironment() -> Configuration? {
 // 首先尝试从Keychain获取配置
            do {
                let keychainConfig = try KeychainManager.shared.retrieveSupabaseConfig()
                guard let url = URL(string: keychainConfig.url) else { return nil }
                return Configuration(url: url, anonKey: keychainConfig.anonKey)
            } catch {
 // 如果Keychain中没有配置，尝试从环境变量获取
                guard let urlString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
                      let url = URL(string: urlString),
                      let anonKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] else {
                    return nil
                }
                
                return Configuration(url: url, anonKey: anonKey)
            }
        }
    }
    
 // MARK: - 错误类型
    
    public enum SupabaseError: LocalizedError {
        case configurationMissing
        case invalidResponse
        case authenticationFailed(String)
        case httpStatus(code: Int, message: String?)
        case schemaMismatch(String)
        case networkError(Error)
        
        public var errorDescription: String? {
            switch self {
            case .configurationMissing:
                return "Supabase配置缺失，请设置SUPABASE_URL和SUPABASE_ANON_KEY环境变量"
            case .invalidResponse:
                return "服务器返回无效响应"
            case .authenticationFailed(let message):
                return "认证失败：\(message)"
            case .httpStatus(let code, let message):
                if let message, !message.isEmpty {
                    return "服务器返回 HTTP \(code)：\(message)"
                }
                return "服务器返回 HTTP \(code)"
            case .schemaMismatch(let message):
                return "Supabase 数据结构不匹配：\(message)"
            case .networkError(let error):
                return "网络错误：\(error.localizedDescription)"
            }
        }

        public var userFacingMessage: String {
            switch self {
            case .configurationMissing:
                return "Supabase 配置缺失，请在设置中配置"
            case .invalidResponse:
                return "服务器返回无效响应"
            case .authenticationFailed(let message):
                return "认证失败：\(message)"
            case .httpStatus(let code, let message):
                switch code {
                case 401:
                    return "会话过期，请重新登录"
                case 403:
                    return "权限不足或会话无效，请确认已登录 Supabase 账号"
                case 429:
                    return "请求过于频繁，请稍后重试"
                default:
                    if code >= 500 {
                        return "服务器暂时不可用，请稍后重试"
                    }
                    if let message, !message.isEmpty {
                        return "服务器返回 HTTP \(code)：\(message)"
                    }
                    return "服务器返回 HTTP \(code)"
                }
            case .schemaMismatch(let message):
                return "Supabase 配置缺失或数据表结构不完整：\(message)"
            case .networkError(let error):
                return "网络错误：\(error.localizedDescription)"
            }
        }
    }

    public static func userMessage(for error: Error) -> String? {
        guard let supabaseError = error as? SupabaseError else { return nil }
        return supabaseError.userFacingMessage
    }
    
 // MARK: - 属性
    
    public static let shared = SupabaseService()

    private enum AvatarSyncResources {
        static let storageBucket = "avatars"
        static let canonicalProfileTable = "user_profiles"
        static let legacyProfileTable = "profiles"
        static let finalizeFunction = "avatar-finalize"
    }

    public struct AvatarFinalizeResponse: Codable, Sendable, Equatable {
        public let avatarId: UUID
        public let avatarURL: String
        public let storagePath: String
        public let universalUserId: UUID
        public let authUserId: UUID
        public let isActive: Bool
        public let projectionStatus: String?
        public let authMetadataMirrored: Bool?

        enum CodingKeys: String, CodingKey {
            case avatarId = "avatar_id"
            case avatarURL = "avatar_url"
            case storagePath = "storage_path"
            case universalUserId = "universal_user_id"
            case authUserId = "auth_user_id"
            case isActive = "is_active"
            case projectionStatus = "projection_status"
            case authMetadataMirrored = "auth_metadata_mirrored"
        }
    }
    
    private let urlSession: URLSession
    private var configuration: Configuration?
    
 // MARK: - 初始化
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)
        
        super.init(category: "SupabaseService")

        let useInMemoryKeychain = ProcessInfo.processInfo.environment["SKYBRIDGE_KEYCHAIN_IN_MEMORY"] == "1"
        self.configuration = useInMemoryKeychain ? nil : Configuration.fromEnvironment()
    }
    
 // MARK: - BaseManager重写
    
    public override func performInitialization() async {
        logger.info("SupabaseService performing initialization")
    }
    
 /// 更新Supabase配置
    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = configuration
    }

 /// 判断 token 是否为当前 Supabase 项目的访问令牌
    public func isSupabaseAccessToken(_ token: String) -> Bool {
        guard let config = configuration else { return false }
        guard let claims = decodeJWTClaims(token),
              let issuer = claims["iss"] as? String else {
            return false
        }
        let expectedIssuer = config.url.appendingPathComponent("auth/v1").absoluteString
        return issuer == expectedIssuer || issuer.hasPrefix(expectedIssuer)
    }

    nonisolated internal static func normalizedRemoteAssetURL(_ raw: String?, baseURL: URL) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }

        if let absoluteURL = URL(string: raw), absoluteURL.scheme != nil {
            return absoluteURL.absoluteString
        }

        return URL(string: raw, relativeTo: baseURL)?.absoluteURL.absoluteString
    }

    private func makeSupabaseRequest(
        url: URL,
        method: String,
        accessToken: String,
        contentType: String? = nil,
        accept: String? = nil
    ) throws -> URLRequest {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        return request
    }

    private func validatedHTTPResponse(
        _ response: URLResponse,
        body: Data,
        successCodes: ClosedRange<Int> = 200...299
    ) throws -> HTTPURLResponse {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError(URLError(.badServerResponse))
        }
        guard successCodes.contains(httpResponse.statusCode) else {
            throw SupabaseError.httpStatus(
                code: httpResponse.statusCode,
                message: String(data: body, encoding: .utf8)
            )
        }
        return httpResponse
    }

    private func fetchFirstStringField(
        fromTable table: String,
        field: String,
        filterColumn: String,
        filterValue: String,
        accessToken: String,
        additionalQueryItems: [URLQueryItem] = []
    ) async -> String? {
        guard let config = configuration else {
            return nil
        }

        let endpoint = config.url.appendingPathComponent("rest/v1/\(table)")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.queryItems = [
            URLQueryItem(name: "select", value: field),
            URLQueryItem(name: filterColumn, value: "eq.\(filterValue)")
        ] + additionalQueryItems
        guard let requestURL = components.url else {
            return nil
        }

        guard let request = try? makeSupabaseRequest(
            url: requestURL,
            method: "GET",
            accessToken: accessToken,
            accept: "application/json"
        ),
        let (data, response) = try? await urlSession.data(for: request),
        let http = response as? HTTPURLResponse,
        http.statusCode == 200,
        let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
        let first = rows.first,
        let raw = first[field] as? String else {
            return nil
        }

        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func storageObjectURL(bucket: String, objectPath: String, isPublic: Bool = false) throws -> URL {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }

        var url = config.url.appendingPathComponent("storage/v1/object")
        if isPublic {
            url.appendPathComponent("public")
        }
        url.appendPathComponent(bucket)
        for component in objectPath.split(separator: "/") {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func finalizeAvatarUpload(
        storagePath: String,
        mimeType: String,
        fileSize: Int,
        width: Int? = nil,
        height: Int? = nil,
        cropData: [String: Any]? = nil,
        accessToken: String
    ) async throws -> AvatarFinalizeResponse {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }

        let endpoint = config.url.appendingPathComponent("functions/v1/\(AvatarSyncResources.finalizeFunction)")
        var request = try makeSupabaseRequest(
            url: endpoint,
            method: "POST",
            accessToken: accessToken,
            contentType: "application/json",
            accept: "application/json"
        )

        var payload: [String: Any] = [
            "storage_path": storagePath,
            "mime_type": mimeType,
            "file_size": fileSize
        ]
        if let width {
            payload["width"] = width
        }
        if let height {
            payload["height"] = height
        }
        if let cropData {
            payload["crop_data"] = cropData
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await urlSession.data(for: request)
        _ = try validatedHTTPResponse(response, body: data)

        guard let finalizeResponse = try? JSONDecoder().decode(AvatarFinalizeResponse.self, from: data),
              !finalizeResponse.avatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SupabaseError.invalidResponse
        }
        return finalizeResponse
    }

    private func projectedAvatarURL(userId: String, accessToken: String) async -> String? {
        guard let projected = await fetchFirstStringField(
            fromTable: AvatarSyncResources.canonicalProfileTable,
            field: "avatar_url",
            filterColumn: "id",
            filterValue: userId,
            accessToken: accessToken,
            additionalQueryItems: [URLQueryItem(name: "limit", value: "1")]
        ) else {
            return nil
        }

        guard let config = configuration else {
            return projected
        }
        return Self.normalizedRemoteAssetURL(projected, baseURL: config.url)
    }

    private func cleanupUploadedAvatarObject(storagePath: String, accessToken: String) async {
        let deleteURL: URL
        do {
            deleteURL = try storageObjectURL(
                bucket: AvatarSyncResources.storageBucket,
                objectPath: storagePath
            )
        } catch {
            return
        }

        guard let request = try? makeSupabaseRequest(
            url: deleteURL,
            method: "DELETE",
            accessToken: accessToken
        ) else {
            return
        }

        _ = try? await urlSession.data(for: request)
    }
    
 // MARK: - 认证方法
    
 /// Apple登录
    public func signInWithApple(identityToken: String, nonce: String? = nil) async throws -> AuthSession {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        let endpoint = config.url.appendingPathComponent("auth/v1/token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")  // 添加 apikey 头
        
        let payload = [
            "provider": "apple",
            "id_token": identityToken,
            "nonce": nonce ?? ""
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        return try await performAuthRequest(request)
    }
    
 /// 邮箱密码登录
    public func signInWithEmail(email: String, password: String) async throws -> AuthSession {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
 // 使用正确的 Supabase Auth API 端点和参数格式
        guard var urlComponents = URLComponents(url: config.url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false) else {
            throw SupabaseError.invalidResponse
        }
        urlComponents.queryItems = [URLQueryItem(name: "grant_type", value: "password")]
        
        guard let endpoint = urlComponents.url else {
            throw SupabaseError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")  // 添加 apikey 头
        
        let payload = [
            "email": email,
            "password": password
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        return try await performAuthRequest(request)
    }
    
 /// 手机号登录
    public func signInWithPhone(phone: String, token: String) async throws -> AuthSession {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        let endpoint = config.url.appendingPathComponent("auth/v1/token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")  // 添加 apikey 头
        
        let payload = [
            "phone": phone,
            "token": token,
            "type": "sms",
            "grant_type": "otp"
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        return try await performAuthRequest(request)
    }
    
 /// 发送手机验证码
    public func sendPhoneOTP(phone: String) async throws {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        let endpoint = config.url.appendingPathComponent("auth/v1/otp")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")  // 添加 apikey 头
        
        let payload = [
            "phone": phone
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await urlSession.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode != 200 {
                throw SupabaseError.authenticationFailed("发送验证码失败")
            }
        } catch {
            throw SupabaseError.networkError(error)
        }
    }
    
 /// 邮箱注册
    public func signUp(email: String, password: String, metadata: [String: Any]? = nil) async throws -> AuthSession {
        SkyBridgeLogger.ui.debugOnly("🔧 [SupabaseService] 开始用户注册")
        SkyBridgeLogger.ui.debugOnly("   邮箱: \(email)")
        SkyBridgeLogger.ui.debugOnly("   元数据: \(String(describing: metadata ?? [:]))")
        
        guard let config = configuration else {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 配置缺失")
            throw SupabaseError.configurationMissing
        }
        
        SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 配置验证通过")
        SkyBridgeLogger.ui.debugOnly("   URL: \(config.url.absoluteString)")
        SkyBridgeLogger.ui.debugOnly("   匿名密钥: \(String(config.anonKey.prefix(10)))...")
        
        let endpoint = config.url.appendingPathComponent("auth/v1/signup")
        SkyBridgeLogger.ui.debugOnly("🌐 [SupabaseService] 请求端点: \(endpoint.absoluteString)")
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")  // 添加 apikey 头
        
        SkyBridgeLogger.ui.debugOnly("🔑 [SupabaseService] 请求头设置完成")
        SkyBridgeLogger.ui.debugOnly("   Content-Type: application/json")
        SkyBridgeLogger.ui.debugOnly("   Authorization: Bearer \(String(config.anonKey.prefix(10)))...")
        SkyBridgeLogger.ui.debugOnly("   apikey: \(String(config.anonKey.prefix(10)))...")
        
        var payload: [String: Any] = [
            "email": email,
            "password": password
        ]
        
        if let metadata = metadata {
            payload["data"] = metadata
        }
        
        SkyBridgeLogger.ui.debugOnly("📦 [SupabaseService] 请求载荷: \(String(describing: payload))")
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 请求载荷序列化成功")
        } catch {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 请求载荷序列化失败: \(error.localizedDescription, privacy: .private)")
            throw error
        }
        
        SkyBridgeLogger.ui.debugOnly("🚀 [SupabaseService] 发送注册请求...")
        
 // 注册请求的特殊处理逻辑
        do {
            let (respData, response) = try await urlSession.data(for: request)
            
            SkyBridgeLogger.ui.debugOnly("📡 [SupabaseService] 收到响应")
            SkyBridgeLogger.ui.debugOnly("   状态码: \(((response as? HTTPURLResponse)?.statusCode ?? 0))")
            SkyBridgeLogger.ui.debugOnly("   响应头: \(String(describing: (response as? HTTPURLResponse)?.allHeaderFields ?? [:]))")
            
            if let responseString = String(data: respData, encoding: .utf8) {
                SkyBridgeLogger.ui.debugOnly("📄 [SupabaseService] 响应内容: \(responseString)")
            }
            
            guard let httpResponse = response as? HTTPURLResponse else {
                SkyBridgeLogger.ui.error("❌ [SupabaseService] 无效的HTTP响应")
                throw SupabaseError.invalidResponse
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 注册成功，解析响应数据")

                // Supabase may return either:
                // - Auth response with access_token (email confirmation disabled), or
                // - Sign-up response without session (email confirmation required).
                if let authResponse = try? JSONDecoder().decode(SupabaseAuthResponse.self, from: respData),
                   !authResponse.accessToken.isEmpty,
                   !authResponse.user.id.isEmpty {
                    let preferredDisplayName =
                        authResponse.user.preferredDisplayName
                        ?? authResponse.user.email
                        ?? authResponse.user.phone
                        ?? "用户"

                    SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 注册返回会话（无需邮箱验证）")
                    SkyBridgeLogger.ui.debugOnly("   用户ID: \(authResponse.user.id)")
                    SkyBridgeLogger.ui.debugOnly("   邮箱: \(authResponse.user.email ?? "无")")

                    return AuthSession(
                        accessToken: authResponse.accessToken,
                        refreshToken: authResponse.refreshToken,
                        userIdentifier: authResponse.user.id,
                        nebulaId: authResponse.user.preferredNebulaId,
                        displayName: preferredDisplayName,
                        avatarURL: Self.normalizedRemoteAssetURL(
                            authResponse.user.preferredAvatarURLRaw,
                            baseURL: config.url
                        ),
                        issuedAt: Date()
                    )
                }

                // 尝试解析注册响应（需要邮箱验证，access_token 缺失）
                do {
                    let signUpResponse = try JSONDecoder().decode(SupabaseSignUpResponse.self, from: respData)
                    SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 注册响应解析成功（待邮箱验证）")
                    SkyBridgeLogger.ui.debugOnly("   用户ID: \(signUpResponse.id)")
                    SkyBridgeLogger.ui.debugOnly("   邮箱: \(signUpResponse.email ?? "无")")
                    SkyBridgeLogger.ui.debugOnly("   确认邮件发送时间: \(signUpResponse.confirmationSentAt ?? "无")")

                    return AuthSession(
                        accessToken: "pending_verification", // 临时令牌，表示等待验证
                        refreshToken: nil,
                        userIdentifier: signUpResponse.id,
                        nebulaId: signUpResponse.preferredNebulaId,
                        displayName: signUpResponse.email ?? "新用户",
                        avatarURL: Self.normalizedRemoteAssetURL(
                            signUpResponse.preferredAvatarURLRaw,
                            baseURL: config.url
                        ),
                        issuedAt: Date()
                    )
                } catch {
                    SkyBridgeLogger.ui.error("❌ [SupabaseService] 注册响应解析失败: \(error.localizedDescription, privacy: .private)")
                    throw SupabaseError.invalidResponse
                }
            } else {
                SkyBridgeLogger.ui.error("❌ [SupabaseService] 注册请求失败，状态码: \(httpResponse.statusCode)")
                
 // 尝试解析错误响应
                do {
                    let errorResponse = try JSONDecoder().decode(SupabaseErrorResponse.self, from: respData)
                    SkyBridgeLogger.ui.error("📄 [SupabaseService] 错误响应: \(errorResponse.message, privacy: .private)")
                    throw SupabaseError.authenticationFailed(errorResponse.message)
                } catch {
                    SkyBridgeLogger.ui.error("❌ [SupabaseService] 错误响应解析失败: \(error.localizedDescription, privacy: .private)")
                    throw SupabaseError.invalidResponse
                }
            }
        } catch let error as SupabaseError {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] Supabase错误: \(String(describing: error), privacy: .private)")
            throw error
        } catch {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 网络请求异常: \(error.localizedDescription, privacy: .private)")
            throw SupabaseError.networkError(error)
        }
    }
    
 /// 重置密码
    public func resetPassword(email: String) async throws {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        let endpoint = config.url.appendingPathComponent("auth/v1/recover")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")  // 添加 apikey 头
        
        let payload = [
            "email": email
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            let (_, response) = try await urlSession.data(for: request)
            
            if let httpResponse = response as? HTTPURLResponse,
               httpResponse.statusCode != 200 {
                throw SupabaseError.authenticationFailed("重置密码失败")
            }
        } catch {
            throw SupabaseError.networkError(error)
        }
    }
    
 // MARK: - 用户资料管理
    
 /// 更新用户资料信息
 /// - Parameters:
 /// - displayName: 新的显示名称（可选）
 /// - phoneNumber: 新的手机号（可选）
 /// - email: 新的邮箱地址（可选）
 /// - accessToken: 用户访问令牌
 /// - Returns: 更新成功标志
    public func updateUserProfile(displayName: String? = nil, 
                                phoneNumber: String? = nil, 
                                email: String? = nil,
                                accessToken: String) async throws -> Bool {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        SkyBridgeLogger.ui.debugOnly("🔄 [SupabaseService] 开始更新用户资料")
        SkyBridgeLogger.ui.debugOnly("   显示名称: \(displayName ?? "无更改")")
        SkyBridgeLogger.ui.debugOnly("   手机号: \(phoneNumber ?? "无更改")")
        SkyBridgeLogger.ui.debugOnly("   邮箱: \(email ?? "无更改")")
        
        let endpoint = config.url.appendingPathComponent("auth/v1/user")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        
 // 构建更新数据
        var updateData: [String: Any] = [:]
        
 // 用户元数据更新
        var userMetadata: [String: Any] = [:]
        if let displayName = displayName {
            userMetadata["display_name"] = displayName
        }
        if let phoneNumber = phoneNumber {
            userMetadata["phone_number"] = phoneNumber
        }
        
        if !userMetadata.isEmpty {
            updateData["data"] = userMetadata
        }
        
 // 邮箱更新（需要单独处理）
        if let email = email {
            updateData["email"] = email
        }
        
        guard !updateData.isEmpty else {
            throw SupabaseError.authenticationFailed("没有需要更新的数据")
        }
        
        request.httpBody = try JSONSerialization.data(withJSONObject: updateData)
        
        SkyBridgeLogger.ui.debugOnly("🌐 [SupabaseService] 发送用户资料更新请求")
        SkyBridgeLogger.ui.debugOnly("   端点: \(endpoint.absoluteString)")
        SkyBridgeLogger.ui.debugOnly("   更新数据: \(String(describing: updateData))")
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SupabaseError.networkError(URLError(.badServerResponse))
            }
            
            SkyBridgeLogger.ui.debugOnly("📡 [SupabaseService] 收到响应，状态码: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 200 {
 // 解析更新后的用户信息
                do {
                    let updateResponse = try JSONDecoder().decode(SupabaseUserUpdateResponse.self, from: data)
                    SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 用户资料更新成功")
                    SkyBridgeLogger.ui.debugOnly("   用户ID: \(updateResponse.id)")
                    SkyBridgeLogger.ui.debugOnly("   邮箱: \(updateResponse.email ?? "无")")
                    SkyBridgeLogger.ui.debugOnly("   手机号: \(updateResponse.phone ?? "无")")
                    
                    return true
                } catch {
                    SkyBridgeLogger.ui.error("❌ [SupabaseService] 用户资料更新响应解析失败: \(error.localizedDescription, privacy: .private)")
                    throw SupabaseError.invalidResponse
                }
            } else {
                SkyBridgeLogger.ui.error("❌ [SupabaseService] 用户资料更新失败，状态码: \(httpResponse.statusCode)")
                
                do {
                    let errorResponse = try JSONDecoder().decode(SupabaseErrorResponse.self, from: data)
                    SkyBridgeLogger.ui.error("   错误消息: \(errorResponse.message, privacy: .private)")
                    throw SupabaseError.httpStatus(code: httpResponse.statusCode, message: errorResponse.message)
                } catch {
                    SkyBridgeLogger.ui.error("   无法解析错误响应: \(error.localizedDescription, privacy: .private)")
                    throw SupabaseError.httpStatus(code: httpResponse.statusCode, message: nil)
                }
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 用户资料更新网络请求失败: \(error.localizedDescription, privacy: .private)")
            if let supabaseError = error as? SupabaseError {
                throw supabaseError
            }
            throw SupabaseError.networkError(error)
        }
    }
    
 /// 通过 profiles 表更新用户资料（备用方案）
 /// - Parameters:
 /// - userId: 用户ID
 /// - displayName: 显示名称
 /// - phoneNumber: 手机号
 /// - accessToken: 访问令牌
 /// - Returns: 更新成功标志
    public func updateProfilesTable(userId: String, displayName: String?, phoneNumber: String?, accessToken: String) async throws -> Bool {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        SkyBridgeLogger.ui.debugOnly("🔄 [SupabaseService] 使用 profiles 表更新用户资料")
        
 // 构建更新数据
        var updateData: [String: Any] = ["updated_at": ISO8601DateFormatter().string(from: Date())]
        if let displayName = displayName { updateData["display_name"] = displayName }
        if let phoneNumber = phoneNumber { updateData["phone_number"] = phoneNumber }
        
 // 使用 REST API 更新 profiles 表
        let endpoint = config.url.appendingPathComponent("rest/v1/profiles")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw SupabaseError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "id", value: "eq.\(userId)")]
        
        guard let requestURL = components.url else {
            throw SupabaseError.invalidResponse
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        request.httpBody = try JSONSerialization.data(withJSONObject: updateData)
        
        let (_, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError(URLError(.badServerResponse))
        }
        
        if httpResponse.statusCode == 200 || httpResponse.statusCode == 204 {
            SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] profiles 表更新成功")
            return true
        } else {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] profiles 表更新失败，状态码: \(httpResponse.statusCode)")
            throw SupabaseError.httpStatus(code: httpResponse.statusCode, message: nil)
        }
    }
    
 // MARK: - 头像管理 (Supabase Storage)
    
 /// 上传头像到 Supabase Storage，然后通过 finalize endpoint 提交头像变更
 /// - Parameters:
 /// - userId: 用户ID
 /// - imageData: 头像图片数据
 /// - accessToken: 用户访问令牌
 /// - Returns: 头像的公开URL
    public func uploadAvatarToStorage(userId: String, imageData: Data, accessToken: String) async throws -> String {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        SkyBridgeLogger.ui.debugOnly("📸 [SupabaseService] 开始上传头像到 Storage")
        SkyBridgeLogger.ui.debugOnly("   用户ID: \(userId)")
        SkyBridgeLogger.ui.debugOnly("   图片大小: \(imageData.count) bytes")
        
 // 构建Storage上传端点
 // 用户头像存放在 avatars bucket，文件名为 <auth_user_id>/<avatar_id>.jpg
        let avatarID = UUID().uuidString.lowercased()
        let fileName = "\(avatarID).jpg"
        let bucketName = AvatarSyncResources.storageBucket
        let storagePath = "\(userId)/\(fileName)"
        let endpoint = try storageObjectURL(
            bucket: bucketName,
            objectPath: storagePath
        )
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        
        request.httpBody = imageData
        
        SkyBridgeLogger.ui.debugOnly("🌐 [SupabaseService] 发送头像上传请求")
        SkyBridgeLogger.ui.debugOnly("   端点: \(endpoint.absoluteString)")
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SupabaseError.networkError(URLError(.badServerResponse))
            }
            
            SkyBridgeLogger.ui.debugOnly("📡 [SupabaseService] 收到上传响应，状态码: \(httpResponse.statusCode)")

            // Supabase Storage may return 200/201/204 depending on create/upsert semantics.
            if (200...299).contains(httpResponse.statusCode) {
 // 构建公开访问URL
                let avatarUrl = try storageObjectURL(
                    bucket: bucketName,
                    objectPath: storagePath,
                    isPublic: true
                ).absoluteString
                
                SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 头像上传成功")
                SkyBridgeLogger.ui.debugOnly("   头像URL: \(avatarUrl)")

                let finalizeResponse: AvatarFinalizeResponse
                do {
                    finalizeResponse = try await finalizeAvatarUpload(
                        storagePath: storagePath,
                        mimeType: "image/jpeg",
                        fileSize: imageData.count,
                        accessToken: accessToken
                    )
                } catch {
                    await cleanupUploadedAvatarObject(storagePath: storagePath, accessToken: accessToken)
                    throw error
                }

                guard let resolvedAvatarURL = await projectedAvatarURL(
                    userId: userId,
                    accessToken: accessToken
                ),
                resolvedAvatarURL == finalizeResponse.avatarURL else {
                    await cleanupUploadedAvatarObject(storagePath: storagePath, accessToken: accessToken)
                    throw SupabaseError.schemaMismatch("头像 finalize 已完成，但 `user_profiles.avatar_url` 回读为空或与 finalize 结果不一致")
                }

                return resolvedAvatarURL
            } else {
                SkyBridgeLogger.ui.error("❌ [SupabaseService] 头像上传失败，状态码: \(httpResponse.statusCode)")
                
                let responseString = String(data: data, encoding: .utf8)
                if let responseString, !responseString.isEmpty {
                    SkyBridgeLogger.ui.error("   错误响应: \(responseString, privacy: .private)")
                }
                
                throw SupabaseError.httpStatus(code: httpResponse.statusCode, message: responseString)
            }
        } catch let error as SupabaseError {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 头像上传失败: \(error.localizedDescription, privacy: .private)")
            throw error
        } catch {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 头像上传网络错误: \(error.localizedDescription, privacy: .private)")
            throw SupabaseError.networkError(error)
        }
    }
    
 /// 获取用户头像URL
 /// - Parameters:
 /// - userId: 用户ID
 /// - accessToken: 访问令牌
 /// - Returns: 头像URL，如果不存在则返回nil
    public func getUserAvatarUrl(userId: String, accessToken: String) async throws -> String? {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        SkyBridgeLogger.ui.debugOnly("🔍 [SupabaseService] 获取用户头像URL")
        SkyBridgeLogger.ui.debugOnly("   用户ID: \(userId)")

        if let projectedAvatarURL = await projectedAvatarURL(
            userId: userId,
            accessToken: accessToken
        ) {
            SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 从 user_profiles 找到用户头像URL: \(projectedAvatarURL)")
            return projectedAvatarURL
        }
        
        let endpoint = config.url.appendingPathComponent("auth/v1/user")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SupabaseError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let userMetadata = json["user_metadata"] as? [String: Any],
                   let avatarUrlRaw = userMetadata["avatar_url"] as? String {
                    if let normalized = Self.normalizedRemoteAssetURL(
                        avatarUrlRaw,
                        baseURL: config.url
                    ) {
                        SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 从 auth metadata 找到用户头像URL: \(normalized)")
                        return normalized
                    }
                }

                func fetchAvatarURLFromTable(_ table: String) async -> String? {
                    let endpoint = config.url.appendingPathComponent("rest/v1/\(table)")
                    guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                        return nil
                    }
                    components.queryItems = [
                        URLQueryItem(name: "select", value: "avatar_url"),
                        URLQueryItem(name: "id", value: "eq.\(userId)"),
                        URLQueryItem(name: "limit", value: "1")
                    ]
                    guard let requestURL = components.url else { return nil }

                    var req = URLRequest(url: requestURL)
                    req.httpMethod = "GET"
                    req.setValue("application/json", forHTTPHeaderField: "Accept")
                    req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                    req.setValue(config.anonKey, forHTTPHeaderField: "apikey")

                    guard let (tableData, tableResponse) = try? await urlSession.data(for: req),
                          let tableHTTP = tableResponse as? HTTPURLResponse,
                          tableHTTP.statusCode == 200,
                          let rows = try? JSONSerialization.jsonObject(with: tableData) as? [[String: Any]],
                          let first = rows.first else {
                        return nil
                    }

                    return Self.normalizedRemoteAssetURL(
                        first["avatar_url"] as? String,
                        baseURL: config.url
                    )
                }

                if let profileAvatar = await fetchAvatarURLFromTable(AvatarSyncResources.legacyProfileTable) {
                    SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 从 profiles 找到用户头像URL: \(profileAvatar)")
                    return profileAvatar
                }

                SkyBridgeLogger.ui.debugOnly("ℹ️ [SupabaseService] 用户未设置头像")
                return nil
            }

            SkyBridgeLogger.ui.error("❌ [SupabaseService] 获取用户信息失败，状态码: \(httpResponse.statusCode)")
            return nil
        } catch {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 获取头像URL失败: \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }

    /// 获取用户 NebulaID（优先读取 user_metadata.nebula_id，必要时回退到 profiles/users 表）
    /// - Parameters:
    ///   - userId: Supabase 用户ID（UUID）
    ///   - accessToken: 访问令牌
    /// - Returns: NebulaID（NEBULA-YYYY-...），若未设置则返回 nil
    public func getUserNebulaId(userId: String, accessToken: String) async throws -> String? {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }

        SkyBridgeLogger.ui.debugOnly("🔍 [SupabaseService] 获取用户 NebulaID")
        SkyBridgeLogger.ui.debugOnly("   用户ID: \(userId)")

        // 1) Prefer Auth user_metadata (cross-device, simplest)
        let authEndpoint = config.url.appendingPathComponent("auth/v1/user")
        var request = URLRequest(url: authEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SupabaseError.networkError(URLError(.badServerResponse))
            }
            if httpResponse.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let userMetadata = json["user_metadata"] as? [String: Any] {
                if let raw = (userMetadata["nebula_id"] as? String) ?? (userMetadata["nebulaId"] as? String) {
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        } catch {
            // Best-effort; fall through to PostgREST lookups.
        }

        func fetchNebulaIdFromTable(_ table: String) async -> String? {
            let endpoint = config.url.appendingPathComponent("rest/v1/\(table)")
            guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
                return nil
            }
            components.queryItems = [
                URLQueryItem(name: "select", value: "nebula_id"),
                URLQueryItem(name: "id", value: "eq.\(userId)"),
                URLQueryItem(name: "limit", value: "1")
            ]
            guard let requestURL = components.url else { return nil }

            var req = URLRequest(url: requestURL)
            req.httpMethod = "GET"
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            req.setValue(config.anonKey, forHTTPHeaderField: "apikey")

            guard let (data, response) = try? await urlSession.data(for: req),
                  let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
                  let first = arr.first,
                  let raw = first["nebula_id"] as? String else {
                return nil
            }

            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // 2) profiles row (recommended schema)
        if let nid = await fetchNebulaIdFromTable("profiles") {
            return nid
        }

        // 3) users table (legacy macOS parity)
        if let nid = await fetchNebulaIdFromTable("users") {
            return nid
        }

        return nil
    }

 // MARK: - 数据库操作
    
 /// 保存 nebulaid 到数据库用户表
 /// - Parameters:
 /// - userId: Supabase 用户ID
 /// - nebulaId: 星云ID
 /// - accessToken: 访问令牌（如果已登录）
 /// - Returns: 是否保存成功
    public func saveNebulaIdToDatabase(userId: String, nebulaId: String, accessToken: String? = nil) async throws -> Bool {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        SkyBridgeLogger.ui.debugOnly("💾 [SupabaseService] 开始保存 NebulaID 到数据库")
        SkyBridgeLogger.ui.debugOnly("   用户ID: \(userId)")
        SkyBridgeLogger.ui.debugOnly("   NebulaID: \(nebulaId)")
        
 // 使用 PostgREST API 更新用户表
 // 注意：表名可能是 'users' 或 'profiles'，根据你的数据库结构调整
        let endpoint = config.url.appendingPathComponent("rest/v1/users")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Content-Profile")
        
        // SECURITY: Never use service-role key from a client app, and avoid anon-key writes to PostgREST.
        // Only allow authenticated user JWT.
        guard let token = accessToken, token != "pending_verification", !token.isEmpty else {
            return false
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        
 // 设置 Prefer 头，只返回更新的行
        request.setValue("return=representation", forHTTPHeaderField: "Prefer")
        
 // 构建更新数据 - 只更新匹配的用户ID
        let updateData: [String: Any] = [
            "nebula_id": nebulaId,
            "updated_at": ISO8601DateFormatter().string(from: Date())
        ]
        
 // 使用 PostgREST 的过滤语法，只更新指定的用户
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "id", value: "eq.\(userId)")]
        guard let filterURL = components?.url else {
            throw SupabaseError.invalidResponse
        }
        request.url = filterURL
        
        request.httpBody = try JSONSerialization.data(withJSONObject: updateData)
        
        SkyBridgeLogger.ui.debugOnly("🌐 [SupabaseService] 发送 NebulaID 保存请求")
        SkyBridgeLogger.ui.debugOnly("   端点: \(filterURL.absoluteString)")
        SkyBridgeLogger.ui.debugOnly("   更新数据: \(String(describing: updateData))")
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SupabaseError.networkError(URLError(.badServerResponse))
            }
            
            SkyBridgeLogger.ui.debugOnly("📡 [SupabaseService] 收到响应，状态码: \(httpResponse.statusCode)")
            
            if (200...299).contains(httpResponse.statusCode) {
                SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] NebulaID 保存成功")
                if let responseString = String(data: data, encoding: .utf8) {
                    SkyBridgeLogger.ui.debugOnly("   响应内容: \(responseString)")
                }
                return true
            } else {
                SkyBridgeLogger.ui.error("❌ [SupabaseService] NebulaID 保存失败，状态码: \(httpResponse.statusCode)")
                
                let responseString = String(data: data, encoding: .utf8)
                if let responseString, !responseString.isEmpty {
                    SkyBridgeLogger.ui.error("   错误响应: \(responseString, privacy: .private)")
                }
                throw SupabaseError.httpStatus(code: httpResponse.statusCode, message: responseString)
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] NebulaID 保存网络请求失败: \(error.localizedDescription, privacy: .private)")
            throw SupabaseError.networkError(error)
        }
    }
    
    // NOTE: We intentionally do NOT provide an insert fallback here.
    // In production, the `user_profiles/profiles` row should be created by server-side logic (DB trigger / Edge Function),
    // and client writes should be governed by RLS using the user's JWT.
    
 // MARK: - 私有方法
    
    private func performAuthRequest(_ request: URLRequest) async throws -> AuthSession {
        SkyBridgeLogger.ui.debugOnly("🔧 [SupabaseService] 执行认证请求")
        SkyBridgeLogger.ui.debugOnly("   方法: \(request.httpMethod ?? "未知")")
        SkyBridgeLogger.ui.debugOnly("   URL: \(request.url?.absoluteString ?? "未知")")
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            SkyBridgeLogger.ui.debugOnly("📥 [SupabaseService] 收到响应")
            SkyBridgeLogger.ui.debugOnly("   数据大小: \(data.count) 字节")
            
            guard let httpResponse = response as? HTTPURLResponse else {
                SkyBridgeLogger.ui.error("❌ [SupabaseService] 无效的HTTP响应")
                throw SupabaseError.invalidResponse
            }
            
            SkyBridgeLogger.ui.debugOnly("📊 [SupabaseService] HTTP响应状态")
            SkyBridgeLogger.ui.debugOnly("   状态码: \(httpResponse.statusCode)")
            SkyBridgeLogger.ui.debugOnly("   响应头: \(String(describing: httpResponse.allHeaderFields))")
            
            if let responseString = String(data: data, encoding: .utf8) {
                SkyBridgeLogger.ui.debugOnly("📄 [SupabaseService] 响应内容: \(responseString)")
            }
            
            if (200...299).contains(httpResponse.statusCode) {
                SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 请求成功，解析响应数据")
                
                do {
                    let authResponse = try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
                    SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 响应解析成功")
                    SkyBridgeLogger.ui.debugOnly("   用户ID: \(authResponse.user.id)")
                    SkyBridgeLogger.ui.debugOnly("   邮箱: \(authResponse.user.email ?? "无")")
                    SkyBridgeLogger.ui.debugOnly("   访问令牌: \(String(authResponse.accessToken.prefix(10)))...")

                    let preferredDisplayName =
                        authResponse.user.preferredDisplayName
                        ?? authResponse.user.email
                        ?? authResponse.user.phone
                        ?? "用户"
                    
                    return AuthSession(
                        accessToken: authResponse.accessToken,
                        refreshToken: authResponse.refreshToken,
                        userIdentifier: authResponse.user.id,
                        nebulaId: authResponse.user.preferredNebulaId,
                        displayName: preferredDisplayName,
                        avatarURL: Self.normalizedRemoteAssetURL(
                            authResponse.user.preferredAvatarURLRaw,
                            baseURL: config.url
                        ),
                        issuedAt: Date()
                    )
                } catch {
                    SkyBridgeLogger.ui.error("❌ [SupabaseService] 响应解析失败: \(error.localizedDescription, privacy: .private)")
                    throw SupabaseError.invalidResponse
                }
            } else {
                SkyBridgeLogger.ui.error("❌ [SupabaseService] 请求失败，状态码: \(httpResponse.statusCode)")
                
                do {
                    let errorResponse = try JSONDecoder().decode(SupabaseErrorResponse.self, from: data)
                    SkyBridgeLogger.ui.error("   错误消息: \(errorResponse.message, privacy: .private)")
                    SkyBridgeLogger.ui.error("   错误描述: \(errorResponse.errorDescription ?? "无", privacy: .private)")
                    throw SupabaseError.httpStatus(code: httpResponse.statusCode, message: errorResponse.message)
                } catch {
                    SkyBridgeLogger.ui.error("   无法解析错误响应: \(error.localizedDescription, privacy: .private)")
                    throw SupabaseError.httpStatus(code: httpResponse.statusCode, message: nil)
                }
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 网络请求异常")
            SkyBridgeLogger.ui.error("   错误类型: \(String(describing: type(of: error)), privacy: .private)")
            SkyBridgeLogger.ui.error("   错误描述: \(error.localizedDescription, privacy: .private)")
            
            if error is SupabaseError {
                throw error
            } else {
                throw SupabaseError.networkError(error)
            }
        }
    }
}

// MARK: - 数据模型

private func decodeJWTClaims(_ token: String) -> [String: Any]? {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    let payload = String(parts[1])
    guard let data = base64URLDecode(payload) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func base64URLDecode(_ input: String) -> Data? {
    var base64 = input.replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 {
        base64.append(String(repeating: "=", count: 4 - remainder))
    }
    return Data(base64Encoded: base64)
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

// 专门用于注册响应的结构体
private struct SupabaseSignUpResponse: Codable {
    let id: String
    let email: String?
    let phone: String?
    let confirmationSentAt: String?
    let createdAt: String
    let updatedAt: String
    let isAnonymous: Bool
    let userMetadata: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case email
        case phone
        case confirmationSentAt = "confirmation_sent_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isAnonymous = "is_anonymous"
        case userMetadata = "user_metadata"
    }

    fileprivate var preferredNebulaId: String? {
        let raw = (userMetadata?["nebula_id"]?.value as? String) ?? (userMetadata?["nebulaId"]?.value as? String)
        return NebulaIdentityContract.normalizedNebulaId(raw)
    }

    fileprivate var preferredAvatarURLRaw: String? {
        let raw = (userMetadata?["avatar_url"]?.value as? String) ?? (userMetadata?["avatarUrl"]?.value as? String)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

private struct SupabaseUser: Codable {
    let id: String
    let email: String?
    let phone: String?
    let createdAt: String?
    let userMetadata: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case id
        case email
        case phone
        case createdAt = "created_at"
        case userMetadata = "user_metadata"
    }

    fileprivate var preferredDisplayName: String? {
        func read(_ key: String) -> String? {
            guard let raw = userMetadata?[key]?.value as? String else { return nil }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }

        // Supabase user_metadata keys (cross-platform parity):
        // - display_name (SkyBridge primary)
        // - full_name / name (OIDC common)
        return read("display_name") ?? read("full_name") ?? read("name")
    }

    fileprivate var preferredNebulaId: String? {
        let raw = (userMetadata?["nebula_id"]?.value as? String) ?? (userMetadata?["nebulaId"]?.value as? String)
        return NebulaIdentityContract.normalizedNebulaId(raw)
    }

    fileprivate var preferredAvatarURLRaw: String? {
        let raw = (userMetadata?["avatar_url"]?.value as? String) ?? (userMetadata?["avatarUrl"]?.value as? String)
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty == false) ? trimmed : nil
    }
}

private struct SupabaseErrorResponse: Codable {
    let message: String
    let errorDescription: String?
    let hint: String?
    
    enum CodingKeys: String, CodingKey {
        case message
        case errorDescription = "error_description"
        case hint
    }
}

// 用户资料更新响应结构体
private struct SupabaseUserUpdateResponse: Codable {
    let id: String
    let email: String?
    let phone: String?
    let createdAt: String
    let updatedAt: String
    let userMetadata: [String: AnyCodable]?
    
    enum CodingKeys: String, CodingKey {
        case id
        case email
        case phone
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case userMetadata = "user_metadata"
    }
}

// 用于处理任意类型的 JSON 值
private struct AnyCodable: Codable {
    let value: Any
    
    init<T>(_ value: T?) {
        self.value = value ?? ()
    }
    
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self.value = ()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dictionary = try? container.decode([String: AnyCodable].self) {
            self.value = dictionary.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "AnyCodable value cannot be decoded")
        }
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        
        switch value {
        case is Void:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map(AnyCodable.init))
        case let dictionary as [String: Any]:
            try container.encode(dictionary.mapValues(AnyCodable.init))
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "AnyCodable value cannot be encoded")
            throw EncodingError.invalidValue(value, context)
        }
    }
    
}

// MARK: - SupabaseService Extension for Token Refresh

extension SupabaseService {
    
 /// 刷新访问令牌
 /// - Parameter refreshToken: 刷新令牌
 /// - Returns: 新的认证会话
    public func refreshAccessToken(_ refreshToken: String) async throws -> AuthSession {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        SkyBridgeLogger.ui.debugOnly("🔄 [SupabaseService] 开始刷新访问令牌")
        
        guard var urlComponents = URLComponents(url: config.url.appendingPathComponent("auth/v1/token"), resolvingAgainstBaseURL: false) else {
            throw SupabaseError.invalidResponse
        }
        urlComponents.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token")]
        guard let endpoint = urlComponents.url else {
            throw SupabaseError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        
        let payload = [
            "refresh_token": refreshToken
        ]
        
        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: payload)
            
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SupabaseError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 200 {
                let authResponse = try JSONDecoder().decode(SupabaseAuthResponse.self, from: data)
                SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 令牌刷新成功")

                let preferredDisplayName =
                    authResponse.user.preferredDisplayName
                    ?? authResponse.user.email
                    ?? authResponse.user.phone
                    ?? "用户"

                return AuthSession(
                    accessToken: authResponse.accessToken,
                    refreshToken: AuthenticationService.mergedRefreshToken(
                        authResponse.refreshToken,
                        fallback: refreshToken
                    ),
                    userIdentifier: authResponse.user.id,
                    nebulaId: authResponse.user.preferredNebulaId,
                    displayName: preferredDisplayName,
                    avatarURL: Self.normalizedRemoteAssetURL(
                        authResponse.user.preferredAvatarURLRaw,
                        baseURL: config.url
                    ),
                    issuedAt: Date()
                )
            } else {
                SkyBridgeLogger.ui.error("❌ [SupabaseService] 令牌刷新失败，状态码: \(httpResponse.statusCode)")
                let responseString = String(data: data, encoding: .utf8)
                throw SupabaseError.httpStatus(code: httpResponse.statusCode, message: responseString)
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 令牌刷新网络错误: \(error.localizedDescription, privacy: .private)")
            throw SupabaseError.networkError(error)
        }
    }
}
