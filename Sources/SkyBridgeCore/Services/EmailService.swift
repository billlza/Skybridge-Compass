import Foundation
import CryptoKit
import os.log

/// 旧客户端邮件服务。
/// 1.0 认证邮件已收敛到 Supabase Auth + 服务端自定义 SMTP，本类型只保留格式校验等辅助能力，发送能力默认停用。
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
        case serviceDisabled(String)
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
            case .serviceDisabled(let message):
                return message
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

        logger.warning("EmailService.authenticateWithPassword 已停用，认证邮件与邮箱登录主链不再走客户端直连邮箱服务")
        throw EmailError.serviceDisabled("邮箱认证已迁移到 Supabase Auth，客户端邮件直连能力在 1.0 中停用")
    }
    
 // MARK: - OAuth2认证
    
 /// 使用OAuth2进行邮箱认证
 /// - Parameter email: 邮箱地址
 /// - Returns: 认证结果
    public func authenticateWithOAuth2(email: String) async throws -> EmailAuthResult {
        guard isValidEmail(email) else {
            throw EmailError.invalidEmailAddress
        }

        logger.warning("EmailService.authenticateWithOAuth2 已停用，认证邮件与邮箱登录主链不再走客户端直连邮箱服务")
        throw EmailError.serviceDisabled("邮箱 OAuth 直连认证未纳入 1.0 主链，请使用 Supabase Auth")
    }
    
 // MARK: - 私有方法
    
 /// 执行SMTP认证
    private func performSMTPAuthentication(
        email: String,
        password: String,
        config: Configuration
    ) async throws -> Bool {
        _ = email
        _ = password
        _ = config
        throw EmailError.serviceDisabled("客户端 SMTP/IMAP 直连认证未纳入 1.0 主链")
    }
    
 /// 发送认证请求到后端
    private func sendAuthenticationRequest(_ request: EmailAuthRequest) async throws -> Bool {
        _ = request
        throw EmailError.serviceDisabled("客户端邮件认证占位请求已停用")
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

        logger.warning("EmailService.sendRegistrationSuccessEmail 已停用，1.0 只保留 Supabase Auth 认证邮件")
        throw EmailError.serviceDisabled("注册成功通知邮件未纳入 1.0 上线范围，当前构建不会从客户端发送占位通知邮件")
    }
    
 /// 发送注册通知邮件请求
    private func sendRegistrationNotificationEmail(_ content: RegistrationSuccessEmailContent) async throws -> Bool {
        _ = content
        throw EmailError.serviceDisabled("客户端注册通知邮件占位请求已停用")
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
