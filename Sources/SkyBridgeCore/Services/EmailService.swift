import Foundation
import CryptoKit
import os.log

/// 邮件服务 - 支持OAuth2和传统密码验证
/// 遵循2025年安全最佳实践，优先使用OAuth2认证 <mcreference link="https://support.google.com/a/answer/9003945?hl=zh-Hans" index="3">3</mcreference>
@MainActor
public final class EmailService: BaseManager {
    
 // MARK: - 生命周期管理
    
    override public func performInitialization() async {
        logger.info("EmailService 初始化完成")
    }
    
 /// 邮件服务配置
    public struct Configuration: Sendable {
        public let smtpHost: String
        public let smtpPort: Int
        public let imapHost: String
        public let imapPort: Int
        public let useTLS: Bool
        public let oauthClientId: String?
        public let oauthClientSecret: String?
        
        public init(smtpHost: String,
                   smtpPort: Int = 587,
                   imapHost: String,
                   imapPort: Int = 993,
                   useTLS: Bool = true,
                   oauthClientId: String? = nil,
                   oauthClientSecret: String? = nil) {
            self.smtpHost = smtpHost
            self.smtpPort = smtpPort
            self.imapHost = imapHost
            self.imapPort = imapPort
            self.useTLS = useTLS
            self.oauthClientId = oauthClientId
            self.oauthClientSecret = oauthClientSecret
        }
        
 /// Gmail配置
        public static let gmail = Configuration(
            smtpHost: "smtp.gmail.com",
            smtpPort: 587,
            imapHost: "imap.gmail.com",
            imapPort: 993,
            useTLS: true
        )
        
 /// Outlook配置
        public static let outlook = Configuration(
            smtpHost: "smtp-mail.outlook.com",
            smtpPort: 587,
            imapHost: "outlook.office365.com",
            imapPort: 993,
            useTLS: true
        )
        
 /// 企业邮箱配置
        public static func enterprise(domain: String) -> Configuration {
            return Configuration(
                smtpHost: "smtp.\(domain)",
                smtpPort: 587,
                imapHost: "imap.\(domain)",
                imapPort: 993,
                useTLS: true
            )
        }
    }
    
 // MARK: - 错误类型
    
    public enum EmailError: LocalizedError {
        case configurationMissing
        case invalidEmailAddress
        case invalidCredentials
        case networkError(Error)
        case authenticationFailed
        case oauthNotSupported
        case serverError(String)
        
        public var errorDescription: String? {
            switch self {
            case .configurationMissing:
                return "邮件服务配置缺失"
            case .invalidEmailAddress:
                return "邮箱地址格式不正确"
            case .invalidCredentials:
                return "邮箱或密码错误"
            case .networkError(let error):
                return "网络连接失败：\(error.localizedDescription)"
            case .authenticationFailed:
                return "邮箱认证失败，请检查账号密码"
            case .oauthNotSupported:
                return "该邮箱服务不支持OAuth2认证"
            case .serverError(let message):
                return "服务器错误：\(message)"
            }
        }
    }
    
 // MARK: - 认证结果
    
    public struct EmailAuthResult: Sendable {
        public let success: Bool
        public let userInfo: EmailUserInfo?
        public let accessToken: String?
        public let refreshToken: String?
        
        public init(success: Bool,
                   userInfo: EmailUserInfo? = nil,
                   accessToken: String? = nil,
                   refreshToken: String? = nil) {
            self.success = success
            self.userInfo = userInfo
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }
    }
    
    public struct EmailUserInfo: Sendable {
        public let email: String
        public let displayName: String?
        public let profilePicture: String?
        
        public init(email: String, displayName: String? = nil, profilePicture: String? = nil) {
            self.email = email
            self.displayName = displayName
            self.profilePicture = profilePicture
        }
    }
    
 // MARK: - 属性
    
    public static let shared = EmailService()
    
    private let urlSession: URLSession
    private var configurations: [String: Configuration] = [:]
    
 // MARK: - 初始化

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        urlSession = URLSession(configuration: config)
        
        super.init(category: "EmailService")
        
 // 预设常用邮箱配置
        setupDefaultConfigurations()
    }
    
 // MARK: - 配置管理
    
 /// 设置默认邮箱配置
    private func setupDefaultConfigurations() {
        configurations["gmail.com"] = .gmail
        configurations["googlemail.com"] = .gmail
        configurations["outlook.com"] = .outlook
        configurations["hotmail.com"] = .outlook
        configurations["live.com"] = .outlook
        
        logger.info("Default email configurations loaded")
    }
    
 /// 添加自定义邮箱配置
    public func addConfiguration(for domain: String, configuration: Configuration) {
        configurations[domain] = configuration
        logger.info("Added configuration for domain: \(domain)")
    }
    
 /// 获取邮箱域名对应的配置
    private func getConfiguration(for email: String) -> Configuration? {
        let domain = String(email.split(separator: "@").last ?? "")
        return configurations[domain.lowercased()]
    }
    
 // MARK: - 邮箱验证
    
 /// 验证邮箱地址格式
    public func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
 // MARK: - 传统密码认证
    
 /// 使用邮箱和密码进行认证
 /// - Parameters:
 /// - email: 邮箱地址
 /// - password: 密码
 /// - Returns: 认证结果
    public func authenticateWithPassword(email: String, password: String) async throws -> EmailAuthResult {
        guard isValidEmail(email) else {
            throw EmailError.invalidEmailAddress
        }
        
        guard let config = getConfiguration(for: email) else {
            throw EmailError.configurationMissing
        }
        
        logger.info("Authenticating email with password: \(email)")
        
        do {
 // 模拟SMTP/IMAP认证过程
            let isAuthenticated = try await performSMTPAuthentication(
                email: email,
                password: password,
                config: config
            )
            
            if isAuthenticated {
                let userInfo = EmailUserInfo(
                    email: email,
                    displayName: extractDisplayName(from: email)
                )
                
                logger.info("Email authentication successful for: \(email)")
                return EmailAuthResult(success: true, userInfo: userInfo)
            } else {
                throw EmailError.invalidCredentials
            }
            
        } catch {
            logger.error("Email authentication failed: \(error.localizedDescription)")
            throw error
        }
    }
    
 // MARK: - OAuth2认证
    
 /// 使用OAuth2进行邮箱认证
 /// - Parameter email: 邮箱地址
 /// - Returns: 认证结果
    public func authenticateWithOAuth2(email: String) async throws -> EmailAuthResult {
        guard isValidEmail(email) else {
            throw EmailError.invalidEmailAddress
        }
        
        guard let config = getConfiguration(for: email),
              config.oauthClientId != nil else {
            throw EmailError.oauthNotSupported
        }
        
        logger.info("Starting OAuth2 authentication for: \(email)")
        
 // 这里应该实现OAuth2流程
 // 由于OAuth2需要浏览器交互，这里提供框架结构
        throw EmailError.oauthNotSupported
    }
    
 // MARK: - 私有方法
    
 /// 执行SMTP认证
    private func performSMTPAuthentication(
        email: String,
        password: String,
        config: Configuration
    ) async throws -> Bool {
 // 构建认证请求
        let authRequest = EmailAuthRequest(
            email: email,
            password: password,
            smtpHost: config.smtpHost,
            smtpPort: config.smtpPort,
            useTLS: config.useTLS
        )
        
 // 发送认证请求到后端服务
        return try await sendAuthenticationRequest(authRequest)
    }
    
 /// 发送认证请求到后端
    private func sendAuthenticationRequest(_ request: EmailAuthRequest) async throws -> Bool {
 // 构建请求URL（这里应该是你的后端API地址）
        guard let url = URL(string: "https://api.skybridge.com/auth/email/verify") else {
            throw EmailError.networkError(URLError(.badURL))
        }
        
 // 创建HTTP请求
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
 // 编码请求体
        let requestData = try JSONEncoder().encode(request)
        httpRequest.httpBody = requestData
        
        do {
            let (data, response) = try await urlSession.data(for: httpRequest)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw EmailError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 200 {
                let authResponse = try JSONDecoder().decode(EmailAuthResponse.self, from: data)
                return authResponse.success
            } else {
                let errorResponse = try? JSONDecoder().decode(EmailErrorResponse.self, from: data)
                throw EmailError.serverError(errorResponse?.message ?? "认证失败")
            }
            
        } catch {
            throw EmailError.networkError(error)
        }
    }
    
 /// 从邮箱地址提取显示名称
    private func extractDisplayName(from email: String) -> String {
        let username = String(email.split(separator: "@").first ?? "")
        return username.capitalized
    }
    
 // MARK: - 注册成功通知
    
 /// 发送注册成功邮件
 /// - Parameters:
 /// - to: 收件人邮箱
 /// - username: 用户名
 /// - nebulaId: Nebula ID
 /// - Returns: 发送结果
    public func sendRegistrationSuccessEmail(to email: String, username: String, nebulaId: String) async throws -> Bool {
        guard isValidEmail(email) else {
            throw EmailError.invalidEmailAddress
        }
        
        logger.info("📧 发送注册成功邮件到: \(email.prefix(3))***")
        
 // 构建邮件内容
        let emailContent = RegistrationSuccessEmailContent(
            recipientEmail: email,
            username: username,
            nebulaId: nebulaId,
            registrationTime: Date(),
            appName: "SkyBridge Compass Pro"
        )
        
        do {
 // 发送邮件请求到后端
            let result = try await sendRegistrationNotificationEmail(emailContent)
            
            if result {
                logger.info("✅ 注册成功邮件已发送: \(email.prefix(3))***")
            } else {
                logger.warning("⚠️ 注册成功邮件发送失败: \(email.prefix(3))***")
            }
            
            return result
        } catch {
            logger.error("❌ 发送注册成功邮件失败: \(error.localizedDescription)")
            throw error
        }
    }
    
 /// 发送注册通知邮件请求
    private func sendRegistrationNotificationEmail(_ content: RegistrationSuccessEmailContent) async throws -> Bool {
 // 构建请求URL
        guard let url = URL(string: "https://api.skybridge.com/notifications/email/registration") else {
            throw EmailError.networkError(URLError(.badURL))
        }
        
 // 创建HTTP请求
        var httpRequest = URLRequest(url: url)
        httpRequest.httpMethod = "POST"
        httpRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
 // 编码请求体
        let requestData = try JSONEncoder().encode(content)
        httpRequest.httpBody = requestData
        
        do {
            let (data, response) = try await urlSession.data(for: httpRequest)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw EmailError.networkError(URLError(.badServerResponse))
            }
            
            if httpResponse.statusCode == 200 {
                let result = try JSONDecoder().decode(EmailNotificationResponse.self, from: data)
                return result.success
            } else {
                let errorResponse = try? JSONDecoder().decode(EmailErrorResponse.self, from: data)
                throw EmailError.serverError(errorResponse?.message ?? "发送失败")
            }
            
        } catch {
 // 如果后端服务不可用，记录日志但不阻塞注册流程
            logger.warning("邮件通知服务暂不可用: \(error.localizedDescription)")
            return false
        }
    }
    
 /// 生成注册成功邮件HTML内容
    public func generateRegistrationSuccessEmailHTML(username: String, nebulaId: String, registrationTime: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy年MM月dd日 HH:mm:ss"
        dateFormatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        let formattedDate = dateFormatter.string(from: registrationTime)
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; background-color: #f5f5f5; padding: 20px; }
                .container { max-width: 600px; margin: 0 auto; background: white; border-radius: 12px; padding: 40px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); }
                .header { text-align: center; margin-bottom: 30px; }
                .logo { font-size: 24px; font-weight: bold; color: #007AFF; }
                .content { color: #333; line-height: 1.6; }
                .highlight { background: linear-gradient(135deg, #007AFF, #5856D6); color: white; padding: 20px; border-radius: 8px; margin: 20px 0; }
                .info-row { display: flex; justify-content: space-between; margin: 10px 0; padding: 10px; background: #f8f9fa; border-radius: 6px; }
                .info-label { color: #666; }
                .info-value { font-weight: 600; color: #333; }
                .footer { text-align: center; margin-top: 30px; color: #999; font-size: 12px; }
            </style>
        </head>
        <body>
            <div class="container">
                <div class="header">
                    <div class="logo">🌌 SkyBridge Compass Pro</div>
                </div>
                
                <div class="content">
                    <h2>🎉 欢迎加入 SkyBridge！</h2>
                    
                    <p>亲爱的 <strong>\(username)</strong>，</p>
                    
                    <p>恭喜您成功注册 SkyBridge Compass Pro 账户！现在您可以开始使用我们的跨平台设备连接和远程控制功能了。</p>
                    
                    <div class="highlight">
                        <h3 style="margin-top: 0;">📋 账户信息</h3>
                        <p><strong>Nebula ID:</strong> \(nebulaId)</p>
                        <p><strong>注册时间:</strong> \(formattedDate)</p>
                    </div>
                    
                    <h3>🚀 开始使用</h3>
                    <ul>
                        <li>下载并安装 SkyBridge 客户端</li>
                        <li>使用您的账户登录</li>
                        <li>添加您的设备并开始连接</li>
                    </ul>
                    
                    <h3>🔒 安全提示</h3>
                    <ul>
                        <li>请妥善保管您的账户密码</li>
                        <li>建议开启双重认证（MFA）</li>
                        <li>如非本人操作，请立即修改密码</li>
                    </ul>
                </div>
                
                <div class="footer">
                    <p>此邮件由 SkyBridge 系统自动发送，请勿直接回复</p>
                    <p>© 2025 SkyBridge. All rights reserved.</p>
                </div>
            </div>
        </body>
        </html>
        """
    }
}

// MARK: - 数据模型

/// 邮箱认证请求
private struct EmailAuthRequest: Codable {
    let email: String
    let password: String
    let smtpHost: String
    let smtpPort: Int
    let useTLS: Bool
}

/// 邮箱认证响应
private struct EmailAuthResponse: Codable {
    let success: Bool
    let message: String?
    let userInfo: EmailUserInfoResponse?
}

/// 邮箱用户信息响应
private struct EmailUserInfoResponse: Codable {
    let email: String
    let displayName: String?
    let profilePicture: String?
}

/// 邮箱错误响应
private struct EmailErrorResponse: Codable {
    let success: Bool
    let message: String
    let code: String?
}

/// 注册成功邮件内容
struct RegistrationSuccessEmailContent: Codable {
    let recipientEmail: String
    let username: String
    let nebulaId: String
    let registrationTime: Date
    let appName: String
}

/// 邮件通知响应
struct EmailNotificationResponse: Codable {
    let success: Bool
    let messageId: String?
}