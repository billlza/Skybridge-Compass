import Foundation
import Combine

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
        public let serviceRoleKey: String?
        
        public init(url: URL, anonKey: String, serviceRoleKey: String? = nil) {
            self.url = url
            self.anonKey = anonKey
            self.serviceRoleKey = serviceRoleKey
        }
        
 /// 从环境变量或Keychain加载配置
        @MainActor
        public static func fromEnvironment() -> Configuration? {
 // 首先尝试从Keychain获取配置
            do {
                let keychainConfig = try KeychainManager.shared.retrieveSupabaseConfig()
                guard let url = URL(string: keychainConfig.url) else { return nil }
                return Configuration(url: url, anonKey: keychainConfig.anonKey, serviceRoleKey: keychainConfig.serviceRoleKey)
            } catch {
 // 如果Keychain中没有配置，尝试从环境变量获取
                guard let urlString = ProcessInfo.processInfo.environment["SUPABASE_URL"],
                      let url = URL(string: urlString),
                      let anonKey = ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"] else {
                    return nil
                }
                
                let serviceRoleKey = ProcessInfo.processInfo.environment["SUPABASE_SERVICE_ROLE_KEY"]
                return Configuration(url: url, anonKey: anonKey, serviceRoleKey: serviceRoleKey)
            }
        }
    }
    
 // MARK: - 错误类型
    
    public enum SupabaseError: LocalizedError {
        case configurationMissing
        case invalidResponse
        case authenticationFailed(String)
        case httpStatus(code: Int, message: String?)
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
    
    private let urlSession: URLSession
    private var configuration: Configuration?
    
 // MARK: - 初始化
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.urlSession = URLSession(configuration: config)
        
        super.init(category: "SupabaseService")
        
        self.configuration = Configuration.fromEnvironment()
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
            
            if httpResponse.statusCode == 200 {
                SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 注册成功，解析响应数据")
                
 // 尝试解析注册响应
                do {
                    let signUpResponse = try JSONDecoder().decode(SupabaseSignUpResponse.self, from: respData)
                    SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 注册响应解析成功")
                    SkyBridgeLogger.ui.debugOnly("   用户ID: \(signUpResponse.id)")
                    SkyBridgeLogger.ui.debugOnly("   邮箱: \(signUpResponse.email ?? "无")")
                    SkyBridgeLogger.ui.debugOnly("   确认邮件发送时间: \(signUpResponse.confirmationSentAt ?? "无")")
                    
 // 注册成功但需要邮箱验证，返回一个特殊的会话
                    return AuthSession(
                        accessToken: "pending_verification", // 临时令牌，表示等待验证
                        refreshToken: nil,
                        userIdentifier: signUpResponse.id,
                        displayName: signUpResponse.email ?? "新用户",
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
    
 /// 上传头像到 Supabase Storage并更新用户metadata
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
 // 用户头像存放在 avatars bucket，文件名为 userId.jpg
        let fileName = "\(userId).jpg"
        let bucketName = "avatars" // 确保在Supabase中创建了这个bucket
        let endpoint = config.url.appendingPathComponent("storage/v1/object/\(bucketName)/\(fileName)")
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
 // 覆盖已存在的文件
        request.setValue("true", forHTTPHeaderField: "x-upsert")
        
        request.httpBody = imageData
        
        SkyBridgeLogger.ui.debugOnly("🌐 [SupabaseService] 发送头像上传请求")
        SkyBridgeLogger.ui.debugOnly("   端点: \(endpoint.absoluteString)")
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SupabaseError.networkError(URLError(.badServerResponse))
            }
            
            SkyBridgeLogger.ui.debugOnly("📡 [SupabaseService] 收到上传响应，状态码: \(httpResponse.statusCode)")
            
            if httpResponse.statusCode == 200 {
 // 构建公开访问URL
                let avatarUrl = "\(config.url.absoluteString)/storage/v1/object/public/\(bucketName)/\(fileName)"
                
                SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 头像上传成功")
                SkyBridgeLogger.ui.debugOnly("   头像URL: \(avatarUrl)")
                
 // 更新用户metadata中的avatar_url
                try await updateUserAvatarUrl(userId: userId, avatarUrl: avatarUrl, accessToken: accessToken)
                
                return avatarUrl
            } else {
                SkyBridgeLogger.ui.error("❌ [SupabaseService] 头像上传失败，状态码: \(httpResponse.statusCode)")
                
                let responseString = String(data: data, encoding: .utf8)
                if let responseString, !responseString.isEmpty {
                    SkyBridgeLogger.ui.error("   错误响应: \(responseString, privacy: .private)")
                }
                
                throw SupabaseError.httpStatus(code: httpResponse.statusCode, message: responseString)
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 头像上传网络错误: \(error.localizedDescription, privacy: .private)")
            throw SupabaseError.networkError(error)
        }
    }
    
 /// 更新用户metadata中的avatar_url
 /// - Parameters:
 /// - userId: 用户ID
 /// - avatarUrl: 头像URL
 /// - accessToken: 访问令牌
    private func updateUserAvatarUrl(userId: String, avatarUrl: String, accessToken: String) async throws {
        guard let config = configuration else {
            throw SupabaseError.configurationMissing
        }
        
        SkyBridgeLogger.ui.debugOnly("💾 [SupabaseService] 更新用户metadata中的avatar_url")
        
        let endpoint = config.url.appendingPathComponent("auth/v1/user")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        
 // 更新用户metadata
        let updateData: [String: Any] = [
            "data": [
                "avatar_url": avatarUrl
            ]
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: updateData)
        
        let (data, response) = try await urlSession.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SupabaseError.networkError(URLError(.badServerResponse))
        }
        
        if httpResponse.statusCode == 200 {
            SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 用户avatar_url已更新到metadata")
        } else {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 更新avatar_url失败，状态码: \(httpResponse.statusCode)")
            
            let responseString = String(data: data, encoding: .utf8)
            if let responseString, !responseString.isEmpty {
                SkyBridgeLogger.ui.error("   错误响应: \(responseString, privacy: .private)")
            }
            
            throw SupabaseError.httpStatus(code: httpResponse.statusCode, message: responseString)
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
                   let avatarUrl = userMetadata["avatar_url"] as? String {
                    SkyBridgeLogger.ui.debugOnly("✅ [SupabaseService] 找到用户头像URL: \(avatarUrl)")
                    return avatarUrl
                } else {
                    SkyBridgeLogger.ui.debugOnly("ℹ️ [SupabaseService] 用户未设置头像")
                    return nil
                }
            } else {
                SkyBridgeLogger.ui.error("❌ [SupabaseService] 获取用户信息失败，状态码: \(httpResponse.statusCode)")
                return nil
            }
        } catch {
            SkyBridgeLogger.ui.error("❌ [SupabaseService] 获取头像URL失败: \(error.localizedDescription, privacy: .private)")
            return nil
        }
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
    // In production, the `users/profiles` row should be created by server-side logic (DB trigger / Edge Function),
    // and client writes should be governed by RLS using the user's JWT.
    
 // MARK: - 私有方法
    
    private func performAuthRequest(_ request: URLRequest) async throws -> AuthSession {
        SkyBridgeLogger.ui.debugOnly("🔧 [SupabaseService] 执行认证请求")
        SkyBridgeLogger.ui.debugOnly("   方法: \(request.httpMethod ?? "未知")")
        SkyBridgeLogger.ui.debugOnly("   URL: \(request.url?.absoluteString ?? "未知")")
        
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
                    
                    return AuthSession(
                        accessToken: authResponse.accessToken,
                        refreshToken: authResponse.refreshToken,
                        userIdentifier: authResponse.user.id,
                        displayName: authResponse.user.email ?? "用户",
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
    
    enum CodingKeys: String, CodingKey {
        case id
        case email
        case phone
        case confirmationSentAt = "confirmation_sent_at"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case isAnonymous = "is_anonymous"
    }
}

private struct SupabaseUser: Codable {
    let id: String
    let email: String?
    let phone: String?
    let createdAt: String
    
    enum CodingKeys: String, CodingKey {
        case id
        case email
        case phone
        case createdAt = "created_at"
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
        
        let endpoint = config.url.appendingPathComponent("auth/v1/token")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.anonKey)", forHTTPHeaderField: "Authorization")
        request.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        
        let payload = [
            "grant_type": "refresh_token",
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
                
                return AuthSession(
                    accessToken: authResponse.accessToken,
                    refreshToken: authResponse.refreshToken,
                    userIdentifier: authResponse.user.id,
                    displayName: authResponse.user.email ?? "用户",
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
