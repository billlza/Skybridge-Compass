import Foundation
import CryptoKit
import os.log

/// 星云登录服务 - 专属企业级身份认证系统
/// 采用JWT + OAuth2混合认证模式，支持多因素认证和SSO <mcreference link="https://v2think.com/do-not-use-token-as-session" index="1">1</mcreference>
@MainActor
public final class NebulaService: BaseManager {
    
 // MARK: - 配置
    
 /// 星云服务配置
    public struct Configuration: Sendable {
        public let baseURL: String
        public let clientId: String
        public let clientSecret: String
        public let redirectURI: String
        public let scopes: [String]
        public let enableMFA: Bool
        public let enableSSO: Bool
        
        public init(baseURL: String,
                   clientId: String,
                   clientSecret: String,
                   redirectURI: String = "skybridge://auth/nebula",
                   scopes: [String] = ["profile", "email", "company"],
                   enableMFA: Bool = true,
                   enableSSO: Bool = true) {
            self.baseURL = baseURL
            self.clientId = clientId
            self.clientSecret = clientSecret
            self.redirectURI = redirectURI
            self.scopes = scopes
            self.enableMFA = enableMFA
            self.enableSSO = enableSSO
        }
        
 /// 生产环境配置 - 使用环境变量
        public static var production: Configuration {
 // 使用环境变量或默认配置，避免同步调用MainActor隔离的方法
            return Configuration(
                baseURL: "https://nebula.skybridge.com",
                clientId: ProcessInfo.processInfo.environment["NEBULA_CLIENT_ID"] ?? "skybridge_compass_pro",
                clientSecret: ProcessInfo.processInfo.environment["NEBULA_CLIENT_SECRET"] ?? "sk_prod_nebula_2025"
            )
        }
        
 /// 开发环境配置 - 使用环境变量
        public static var development: Configuration {
 // 使用环境变量或默认配置，避免同步调用MainActor隔离的方法
            return Configuration(
                baseURL: "https://nebula-dev.skybridge.com",
                clientId: ProcessInfo.processInfo.environment["NEBULA_CLIENT_ID"] ?? "skybridge_compass_dev",
                clientSecret: ProcessInfo.processInfo.environment["NEBULA_CLIENT_SECRET"] ?? "sk_dev_nebula_2025"
            )
        }
    }
    
 // MARK: - 错误类型
    
    public enum NebulaError: LocalizedError {
        case configurationMissing
        case invalidCredentials
        case networkError(Error)
        case authenticationFailed
        case mfaRequired
        case mfaFailed
        case tokenExpired
        case refreshTokenInvalid
        case serverError(String)
        case userNotFound
        case companyNotAuthorized
        
        public var errorDescription: String? {
            switch self {
            case .configurationMissing:
                return "星云服务配置缺失"
            case .invalidCredentials:
                return "用户名或密码错误"
            case .networkError(let error):
                return "网络连接失败：\(error.localizedDescription)"
            case .authenticationFailed:
                return "星云认证失败，请检查账号信息"
            case .mfaRequired:
                return "需要多因素认证验证"
            case .mfaFailed:
                return "多因素认证验证失败"
            case .tokenExpired:
                return "访问令牌已过期"
            case .refreshTokenInvalid:
                return "刷新令牌无效"
            case .serverError(let message):
                return "服务器错误：\(message)"
            case .userNotFound:
                return "用户不存在或未激活"
            case .companyNotAuthorized:
                return "公司账户未授权访问"
            }
        }
    }
    
 // MARK: - 认证结果
    
    public struct NebulaAuthResult: Sendable {
        public let success: Bool
        public let userInfo: NebulaUserInfo?
        public let accessToken: String?
        public let refreshToken: String?
        public let expiresIn: TimeInterval?
        public let mfaRequired: Bool
        public let mfaToken: String?
        
        public init(success: Bool,
                   userInfo: NebulaUserInfo? = nil,
                   accessToken: String? = nil,
                   refreshToken: String? = nil,
                   expiresIn: TimeInterval? = nil,
                   mfaRequired: Bool = false,
                   mfaToken: String? = nil) {
            self.success = success
            self.userInfo = userInfo
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresIn = expiresIn
            self.mfaRequired = mfaRequired
            self.mfaToken = mfaToken
        }
    }
    
    public struct NebulaUserInfo: Sendable {
        public let userId: String
        public let username: String
        public let email: String
        public let displayName: String
        public let avatar: String?
        public let companyId: String
        public let companyName: String
        public let department: String?
        public let role: String
        public let permissions: [String]
        public let lastLoginAt: Date?
        
        public init(userId: String,
                   username: String,
                   email: String,
                   displayName: String,
                   avatar: String? = nil,
                   companyId: String,
                   companyName: String,
                   department: String? = nil,
                   role: String,
                   permissions: [String] = [],
                   lastLoginAt: Date? = nil) {
            self.userId = userId
            self.username = username
            self.email = email
            self.displayName = displayName
            self.avatar = avatar
            self.companyId = companyId
            self.companyName = companyName
            self.department = department
            self.role = role
            self.permissions = permissions
            self.lastLoginAt = lastLoginAt
        }
    }
    
 // MARK: - 属性
    
    public static let shared = NebulaService()
    
    private let urlSession: URLSession
    private var configuration: Configuration?
    private let idGenerator = NebulaIDGenerator.shared
    
 // MARK: - 初始化
    
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        urlSession = URLSession(configuration: config)
        
        super.init(category: "NebulaService")
        
 // 根据构建配置设置默认配置
        #if DEBUG
        self.configuration = .development
        #else
        self.configuration = .production
        #endif
        
        logger.info("NebulaService initialized with configuration")
    }
    
 // MARK: - BaseManager重写
    
    public override func performInitialization() async {
        logger.info("NebulaService performing initialization")
    }
    
 // MARK: - 配置管理
    
 /// 设置星云服务配置
    public func setConfiguration(_ config: Configuration) {
        self.configuration = config
        logger.info("NebulaService configuration updated")
    }
    
 // MARK: - 用户名密码认证
    
 /// 使用用户名和密码进行星云认证
 /// - Parameters:
 /// - username: 用户名
 /// - password: 密码
 /// - Returns: 认证结果
    public func authenticateWithCredentials(username: String, password: String) async throws -> NebulaAuthResult {
        guard let config = configuration else {
            throw NebulaError.configurationMissing
        }
        
        logger.info("Starting Nebula authentication for user: \(username)")
        
        do {
 // 构建认证请求
            let authRequest = NebulaAuthRequest(
                username: username,
                password: password,
                clientId: config.clientId,
                clientSecret: config.clientSecret,
                scopes: config.scopes
            )
            
 // 发送认证请求
            let result = try await sendAuthenticationRequest(authRequest, config: config)
            
            if result.mfaRequired {
                logger.info("MFA required for user: \(username)")
                return result
            }
            
            if result.success {
                logger.info("Nebula authentication successful for user: \(username)")
            }
            
            return result
            
        } catch {
            logger.error("Nebula authentication failed: \(error.localizedDescription)")
            throw error
        }
    }
    
 // MARK: - 多因素认证
    
 /// 验证多因素认证码
 /// - Parameters:
 /// - mfaToken: MFA令牌
 /// - code: 验证码
 /// - Returns: 认证结果
    public func verifyMFA(mfaToken: String, code: String) async throws -> NebulaAuthResult {
        guard let config = configuration else {
            throw NebulaError.configurationMissing
        }
        
        logger.info("Verifying MFA code")
        
        do {
            let mfaRequest = NebulaMFARequest(
                mfaToken: mfaToken,
                code: code,
                clientId: config.clientId
            )
            
            let result = try await sendMFARequest(mfaRequest, config: config)
            
            if result.success {
                logger.info("MFA verification successful")
            }
            
            return result
            
        } catch {
            logger.error("MFA verification failed: \(error.localizedDescription)")
            throw error
        }
    }
    
 // MARK: - 令牌刷新
    
 /// 刷新访问令牌
 /// - Parameter refreshToken: 刷新令牌
 /// - Returns: 新的认证结果
    public func refreshAccessToken(_ refreshToken: String) async throws -> NebulaAuthResult {
        guard let config = configuration else {
            throw NebulaError.configurationMissing
        }
        
        logger.info("Refreshing access token")
        
        do {
            let refreshRequest = NebulaRefreshRequest(
                refreshToken: refreshToken,
                clientId: config.clientId,
                clientSecret: config.clientSecret
            )
            
            let result = try await sendRefreshRequest(refreshRequest, config: config)
            
            if result.success {
                logger.info("Token refresh successful")
            }
            
            return result
            
        } catch {
            logger.error("Token refresh failed: \(error.localizedDescription)")
            throw error
        }
    }
    
 // MARK: - 用户注册
    
 /// 星云用户注册
 /// - Parameters:
 /// - username: 用户名
 /// - password: 密码
 /// - email: 邮箱地址
 /// - displayName: 显示名称
 /// - companyId: 公司ID（可选）
 /// - Returns: 注册结果
    public func registerUser(username: String, 
                           password: String, 
                           email: String, 
                           displayName: String,
                           companyId: String? = nil) async throws -> NebulaRegistrationResult {
        guard let config = configuration else {
            throw NebulaError.configurationMissing
        }
        
        logger.info("开始星云用户注册: \(username)")
        
        do {
 // 生成用户ID
            let userIdInfo = try idGenerator.generateUserRegistrationID()
            
 // 构建注册请求
            let registrationRequest = NebulaRegistrationRequest(
                userId: userIdInfo.fullId,
                username: username,
                password: password,
                email: email,
                displayName: displayName,
                companyId: companyId,
                clientId: config.clientId,
                clientSecret: config.clientSecret
            )
            
 // 发送注册请求
            let result = try await sendRegistrationRequest(registrationRequest, config: config)
            
            if result.success {
                logger.info("星云用户注册成功: \(username), ID: \(userIdInfo.fullId)")
            }
            
            return result
            
        } catch {
            logger.error("星云用户注册失败: \(error.localizedDescription)")
            throw error
        }
    }
    
 /// 检查用户名可用性
 /// - Parameter username: 用户名
 /// - Returns: 是否可用
    public func checkUsernameAvailability(_ username: String) async throws -> Bool {
        guard let config = configuration else {
            throw NebulaError.configurationMissing
        }
        
        guard let url = URL(string: "\(config.baseURL)/auth/check-username") else {
            throw NebulaError.networkError(URLError(.badURL))
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let checkRequest = ["username": username, "clientId": config.clientId]
        request.httpBody = try JSONEncoder().encode(checkRequest)
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NebulaError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 200 {
                let checkResponse = try JSONDecoder().decode(UsernameCheckResponse.self, from: data)
                return checkResponse.available
            } else {
                return false
            }
            
        } catch {
            throw NebulaError.networkError(error)
        }
    }
    
 // MARK: - 用户信息更新
    
 /// 更新用户显示名称
 /// - Parameters:
 /// - userId: 用户ID
 /// - displayName: 新的显示名称
 /// - accessToken: 访问令牌
 /// - Returns: 更新后的用户信息
    public func updateDisplayName(userId: String, displayName: String, accessToken: String) async throws -> NebulaUserInfo {
        guard let config = configuration else {
            throw NebulaError.configurationMissing
        }
        
        logger.info("开始更新用户显示名称: \(userId)")
        
        guard let url = URL(string: "\(config.baseURL)/user/profile/display-name") else {
            throw NebulaError.networkError(URLError(.badURL))
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let updateRequest = UserDisplayNameUpdateRequest(
            userId: userId,
            displayName: displayName,
            clientId: config.clientId
        )
        
        request.httpBody = try JSONEncoder().encode(updateRequest)
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NebulaError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 200 {
                let updateResponse = try JSONDecoder().decode(UserUpdateResponse.self, from: data)
                if updateResponse.success {
                    logger.info("用户显示名称更新成功: \(userId)")
 // 将NebulaUserInfoResponse转换为NebulaUserInfo
                    let userInfo = updateResponse.userInfo
                    let dateFormatter = ISO8601DateFormatter()
                    let lastLoginAt = userInfo.lastLoginAt.flatMap { dateFormatter.date(from: $0) }
                    
                    return NebulaUserInfo(
                        userId: userInfo.userId,
                        username: userInfo.username,
                        email: userInfo.email,
                        displayName: userInfo.displayName,
                        avatar: userInfo.avatar,
                        companyId: userInfo.companyId,
                        companyName: userInfo.companyName,
                        department: userInfo.department,
                        role: userInfo.role,
                        permissions: userInfo.permissions,
                        lastLoginAt: lastLoginAt
                    )
                } else {
                    throw NebulaError.serverError(updateResponse.message ?? "更新失败")
                }
            } else {
                let errorResponse = try? JSONDecoder().decode(NebulaErrorResponse.self, from: data)
                throw NebulaError.serverError(errorResponse?.message ?? "更新显示名称失败")
            }
            
        } catch {
            logger.error("用户显示名称更新失败: \(error.localizedDescription)")
            throw NebulaError.networkError(error)
        }
    }
    
 /// 上传用户头像
 /// - Parameters:
 /// - userId: 用户ID
 /// - imageData: 头像图片数据
 /// - accessToken: 访问令牌
 /// - Returns: 头像URL
    public func uploadAvatar(userId: String, imageData: Data, accessToken: String) async throws -> String {
        guard let config = configuration else {
            throw NebulaError.configurationMissing
        }
        
        logger.info("开始上传用户头像: \(userId), 大小: \(imageData.count) bytes")
        
        guard let url = URL(string: "\(config.baseURL)/user/profile/avatar") else {
            throw NebulaError.networkError(URLError(.badURL))
        }
        
 // 创建multipart/form-data请求
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
 // 构建multipart数据
        var body = Data()
        
 // 添加用户ID字段
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"userId\"\r\n\r\n".utf8Data)
        body.append("\(userId)\r\n".utf8Data)
        
 // 添加客户端ID字段
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"clientId\"\r\n\r\n".utf8Data)
        body.append("\(config.clientId)\r\n".utf8Data)
        
 // 添加图片文件
        body.append("--\(boundary)\r\n".utf8Data)
        body.append("Content-Disposition: form-data; name=\"avatar\"; filename=\"avatar.jpg\"\r\n".utf8Data)
        body.append("Content-Type: image/jpeg\r\n\r\n".utf8Data)
        body.append(imageData)
        body.append("\r\n".utf8Data)
        
 // 结束边界
        body.append("--\(boundary)--\r\n".utf8Data)
        
        request.httpBody = body
        
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NebulaError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 200 {
                let uploadResponse = try JSONDecoder().decode(AvatarUploadResponse.self, from: data)
                if uploadResponse.success {
                    logger.info("用户头像上传成功: \(userId), URL: \(uploadResponse.avatarUrl)")
                    return uploadResponse.avatarUrl
                } else {
                    throw NebulaError.serverError(uploadResponse.message ?? "头像上传失败")
                }
            } else {
                let errorResponse = try? JSONDecoder().decode(NebulaErrorResponse.self, from: data)
                throw NebulaError.serverError(errorResponse?.message ?? "头像上传失败")
            }
            
        } catch {
            logger.error("用户头像上传失败: \(error.localizedDescription)")
            throw NebulaError.networkError(error)
        }
    }
    
 /// 更新用户完整信息（显示名称和头像）
 /// - Parameters:
 /// - userId: 用户ID
 /// - displayName: 新的显示名称（可选）
 /// - imageData: 头像图片数据（可选）
 /// - accessToken: 访问令牌
 /// - Returns: 更新后的用户信息
    public func updateUserProfile(userId: String, 
                                displayName: String? = nil, 
                                imageData: Data? = nil, 
                                accessToken: String) async throws -> NebulaUserInfo {
        logger.info("开始更新用户完整信息: \(userId)")
        
        var updatedUserInfo: NebulaUserInfo?
        var avatarUrl: String?
        
 // 如果需要更新显示名称
        if let displayName = displayName, !displayName.isEmpty {
            updatedUserInfo = try await updateDisplayName(userId: userId, displayName: displayName, accessToken: accessToken)
        }
        
 // 如果需要上传头像
        if let imageData = imageData {
            avatarUrl = try await uploadAvatar(userId: userId, imageData: imageData, accessToken: accessToken)
            if let avatarUrl {
                logger.info("头像上传成功，URL: \(avatarUrl)")
            }
        }
        
 // 构建最终的用户信息
        let finalUserInfo: NebulaUserInfo
        if let userInfo = updatedUserInfo {
 // 如果有头像更新，需要更新头像URL
            if let avatarUrl = avatarUrl {
                finalUserInfo = NebulaUserInfo(
                    userId: userInfo.userId,
                    username: userInfo.username,
                    email: userInfo.email,
                    displayName: userInfo.displayName,
                    avatar: avatarUrl,
                    companyId: userInfo.companyId,
                    companyName: userInfo.companyName,
                    department: userInfo.department,
                    role: userInfo.role,
                    permissions: userInfo.permissions,
                    lastLoginAt: userInfo.lastLoginAt
                )
            } else {
                finalUserInfo = userInfo
            }
        } else if avatarUrl != nil {
 // 只更新了头像，需要从现有用户信息获取其他字段
 // 这种情况下应该先获取当前用户信息，然后更新头像
            throw NebulaError.serverError("仅更新头像时需要先获取完整的用户信息")
        } else {
            throw NebulaError.serverError("没有进行任何更新操作")
        }
        
        logger.info("用户信息更新完成: \(userId)")
        return finalUserInfo
    }
    
 /// 发送认证请求
    private func sendAuthenticationRequest(_ request: NebulaAuthRequest, config: Configuration) async throws -> NebulaAuthResult {
        guard let url = URL(string: "\(config.baseURL)/auth/login") else {
            throw NebulaError.networkError(URLError(.badURL))
        }
        
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("SkyBridge-Compass/1.0", forHTTPHeaderField: "User-Agent")
        
        let requestData = try JSONEncoder().encode(request)
        httpRequest.httpBody = requestData
        
        do {
            let (data, response) = try await urlSession.data(for: httpRequest)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NebulaError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 200 {
                let authResponse = try JSONDecoder().decode(NebulaAuthResponse.self, from: data)
                return convertToAuthResult(authResponse)
            } else {
                let errorResponse = try? JSONDecoder().decode(NebulaErrorResponse.self, from: data)
                throw NebulaError.serverError(errorResponse?.message ?? "认证失败")
            }
            
        } catch {
            throw NebulaError.networkError(error)
        }
    }
    
 /// 发送MFA请求
    private func sendMFARequest(_ request: NebulaMFARequest, config: Configuration) async throws -> NebulaAuthResult {
        guard let url = URL(string: "\(config.baseURL)/auth/mfa/verify") else {
            throw NebulaError.networkError(URLError(.badURL))
        }
        
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestData = try JSONEncoder().encode(request)
        httpRequest.httpBody = requestData
        
        do {
            let (data, response) = try await urlSession.data(for: httpRequest)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NebulaError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 200 {
                let authResponse = try JSONDecoder().decode(NebulaAuthResponse.self, from: data)
                return convertToAuthResult(authResponse)
            } else {
                throw NebulaError.mfaFailed
            }
            
        } catch {
            throw NebulaError.networkError(error)
        }
    }
    
 /// 发送刷新令牌请求
    private func sendRefreshRequest(_ request: NebulaRefreshRequest, config: Configuration) async throws -> NebulaAuthResult {
        guard let url = URL(string: "\(config.baseURL)/auth/refresh") else {
            throw NebulaError.networkError(URLError(.badURL))
        }
        
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let requestData = try JSONEncoder().encode(request)
        httpRequest.httpBody = requestData
        
        do {
            let (data, response) = try await urlSession.data(for: httpRequest)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NebulaError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 200 {
                let authResponse = try JSONDecoder().decode(NebulaAuthResponse.self, from: data)
                return convertToAuthResult(authResponse)
            } else {
                throw NebulaError.refreshTokenInvalid
            }
            
        } catch {
            throw NebulaError.networkError(error)
        }
    }
    
 /// 转换认证响应为结果
    private func convertToAuthResult(_ response: NebulaAuthResponse) -> NebulaAuthResult {
        let userInfo: NebulaUserInfo?
        if let responseUserInfo = response.userInfo {
            let dateFormatter = ISO8601DateFormatter()
            let lastLoginAt = responseUserInfo.lastLoginAt.flatMap { dateFormatter.date(from: $0) }
            
            userInfo = NebulaUserInfo(
                userId: responseUserInfo.userId,
                username: responseUserInfo.username,
                email: responseUserInfo.email,
                displayName: responseUserInfo.displayName,
                avatar: responseUserInfo.avatar,
                companyId: responseUserInfo.companyId,
                companyName: responseUserInfo.companyName,
                department: responseUserInfo.department,
                role: responseUserInfo.role,
                permissions: responseUserInfo.permissions,
                lastLoginAt: lastLoginAt
            )
        } else {
            userInfo = nil
        }
        
        return NebulaAuthResult(
            success: response.success,
            userInfo: userInfo,
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expiresIn: response.expiresIn,
            mfaRequired: response.mfaRequired ?? false,
            mfaToken: response.mfaToken
        )
    }
    
 /// 发送注册请求
    private func sendRegistrationRequest(_ request: NebulaRegistrationRequest, config: Configuration) async throws -> NebulaRegistrationResult {
        guard let url = URL(string: "\(config.baseURL)/auth/register") else {
            throw NebulaError.networkError(URLError(.badURL))
        }
        
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        httpRequest.setValue("SkyBridge-Compass/1.0", forHTTPHeaderField: "User-Agent")
        
        let requestData = try JSONEncoder().encode(request)
        httpRequest.httpBody = requestData
        
        do {
            let (data, response) = try await urlSession.data(for: httpRequest)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw NebulaError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 201 {
                let registrationResponse = try JSONDecoder().decode(NebulaRegistrationResponse.self, from: data)
                return convertToRegistrationResult(registrationResponse)
            } else {
                let errorResponse = try? JSONDecoder().decode(NebulaErrorResponse.self, from: data)
                throw NebulaError.serverError(errorResponse?.message ?? "注册失败")
            }
            
        } catch {
            throw NebulaError.networkError(error)
        }
    }
    
 /// 转换注册响应为结果
    private func convertToRegistrationResult(_ response: NebulaRegistrationResponse) -> NebulaRegistrationResult {
        return NebulaRegistrationResult(
            success: response.success,
            userId: response.userId,
            username: response.username,
            email: response.email,
            displayName: response.displayName,
            message: response.message,
            requiresEmailVerification: response.requiresEmailVerification ?? false,
            requiresAdminApproval: response.requiresAdminApproval ?? false
        )
    }
}

// MARK: - 数据模型

/// 星云认证请求
private struct NebulaAuthRequest: Codable {
    let username: String
    let password: String
    let clientId: String
    let clientSecret: String
    let scopes: [String]
}

/// 星云MFA请求
private struct NebulaMFARequest: Codable {
    let mfaToken: String
    let code: String
    let clientId: String
}

/// 星云刷新令牌请求
private struct NebulaRefreshRequest: Codable {
    let refreshToken: String
    let clientId: String
    let clientSecret: String
}

/// 星云认证响应
private struct NebulaAuthResponse: Codable {
    let success: Bool
    let message: String?
    let userInfo: NebulaUserInfoResponse?
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: TimeInterval?
    let mfaRequired: Bool?
    let mfaToken: String?
}

/// 星云用户信息响应
private struct NebulaUserInfoResponse: Codable {
    let userId: String
    let username: String
    let email: String
    let displayName: String
    let avatar: String?
    let companyId: String
    let companyName: String
    let department: String?
    let role: String
    let permissions: [String]
    let lastLoginAt: String?
}

/// 星云错误响应
private struct NebulaErrorResponse: Codable {
    let success: Bool
    let message: String
    let code: String?
}

// MARK: - 注册相关数据模型

/// 星云注册结果
public struct NebulaRegistrationResult: Sendable {
    public let success: Bool
    public let userId: String?
    public let username: String?
    public let email: String?
    public let displayName: String?
    public let message: String?
    public let requiresEmailVerification: Bool
    public let requiresAdminApproval: Bool
    
    public init(success: Bool,
               userId: String? = nil,
               username: String? = nil,
               email: String? = nil,
               displayName: String? = nil,
               message: String? = nil,
               requiresEmailVerification: Bool = false,
               requiresAdminApproval: Bool = false) {
        self.success = success
        self.userId = userId
        self.username = username
        self.email = email
        self.displayName = displayName
        self.message = message
        self.requiresEmailVerification = requiresEmailVerification
        self.requiresAdminApproval = requiresAdminApproval
    }
}

/// 星云注册请求
private struct NebulaRegistrationRequest: Codable {
    let userId: String
    let username: String
    let password: String
    let email: String
    let displayName: String
    let companyId: String?
    let clientId: String
    let clientSecret: String
}

/// 星云注册响应
private struct NebulaRegistrationResponse: Codable {
    let success: Bool
    let userId: String?
    let username: String?
    let email: String?
    let displayName: String?
    let message: String?
    let requiresEmailVerification: Bool?
    let requiresAdminApproval: Bool?
}

/// 用户名检查响应
private struct UsernameCheckResponse: Codable {
    let available: Bool
    let message: String?
}

// MARK: - 用户信息更新相关数据模型

/// 用户显示名称更新请求
private struct UserDisplayNameUpdateRequest: Codable {
    let userId: String
    let displayName: String
    let clientId: String
}

/// 用户信息更新响应
private struct UserUpdateResponse: Codable {
    let success: Bool
    let message: String?
    let userInfo: NebulaUserInfoResponse
}

/// 头像上传响应
private struct AvatarUploadResponse: Codable {
    let success: Bool
    let message: String?
    let avatarUrl: String
}
