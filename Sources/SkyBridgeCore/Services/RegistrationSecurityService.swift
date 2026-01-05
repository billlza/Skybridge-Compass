import Foundation
import CryptoKit
import os.log

/// 注册安全服务 - 防止恶意注册的核心安全组件
///
/// 功能：
/// - 多维度限流（IP/设备指纹/账号）
/// - 输入清洗与校验
/// - 恶意行为检测与记录
/// - 黑名单管理
///
/// 使用 Swift 6.2.1 actor 确保线程安全
@available(macOS 14.0, *)
public actor RegistrationSecurityService {
    
 // MARK: - 单例
    
    public static let shared = RegistrationSecurityService()
    
 // MARK: - 配置
    
 /// 限流配置
    public struct RateLimitConfig: Sendable {
 /// 同一IP每分钟最大注册尝试次数
        public let ipMaxPerMinute: Int
 /// 同一设备每小时最大注册尝试次数
        public let deviceMaxPerHour: Int
 /// 同一账号（手机号/邮箱）每天最大注册尝试次数
        public let identifierMaxPerDay: Int
 /// 全局每秒最大注册请求数
        public let globalMaxPerSecond: Int
 /// 触发行为验证的阈值（同一IP/设备的尝试次数）
        public let captchaTriggerThreshold: Int
        
        public init(
            ipMaxPerMinute: Int = 5,
            deviceMaxPerHour: Int = 3,
            identifierMaxPerDay: Int = 5,
            globalMaxPerSecond: Int = 10,
            captchaTriggerThreshold: Int = 2
        ) {
            self.ipMaxPerMinute = ipMaxPerMinute
            self.deviceMaxPerHour = deviceMaxPerHour
            self.identifierMaxPerDay = identifierMaxPerDay
            self.globalMaxPerSecond = globalMaxPerSecond
            self.captchaTriggerThreshold = captchaTriggerThreshold
        }
        
 /// 默认配置
        public static let `default` = RateLimitConfig()
        
 /// 严格配置（用于高风险场景）
        public static let strict = RateLimitConfig(
            ipMaxPerMinute: 3,
            deviceMaxPerHour: 2,
            identifierMaxPerDay: 3,
            globalMaxPerSecond: 5,
            captchaTriggerThreshold: 1
        )
    }
    
 // MARK: - 数据模型
    
 /// 注册上下文 - 包含注册请求的所有相关信息
    public struct RegistrationContext: Sendable, Codable {
        public let ip: String
        public let deviceFingerprint: String
        public let identifier: String  // 手机号或邮箱（哈希存储）
        public let identifierType: IdentifierType
        public let timestamp: Date
        public let userAgent: String?
        
        public enum IdentifierType: String, Sendable, Codable {
            case phone
            case email
            case username
        }
        
        public init(
            ip: String,
            deviceFingerprint: String,
            identifier: String,
            identifierType: IdentifierType,
            timestamp: Date = Date(),
            userAgent: String? = nil
        ) {
            self.ip = ip
            self.deviceFingerprint = deviceFingerprint
            self.identifier = identifier
            self.identifierType = identifierType
            self.timestamp = timestamp
            self.userAgent = userAgent
        }
        
 /// 生成标识符的哈希值（用于存储）
        public var identifierHash: String {
            let data = identifier.utf8Data
            let hash = SHA256.hash(data: data)
            return hash.compactMap { String(format: "%02x", $0) }.joined()
        }
    }
    
 /// 注册尝试记录
    public struct RegistrationAttempt: Sendable, Codable {
        public let id: UUID
        public let context: RegistrationContext
        public let success: Bool
        public let failureReason: String?
        public let createdAt: Date
        
        public init(
            id: UUID = UUID(),
            context: RegistrationContext,
            success: Bool,
            failureReason: String? = nil,
            createdAt: Date = Date()
        ) {
            self.id = id
            self.context = context
            self.success = success
            self.failureReason = failureReason
            self.createdAt = createdAt
        }
    }
    
 /// 限流检查结果
    public struct RateLimitResult: Sendable {
        public let allowed: Bool
        public let reason: String?
        public let requiresCaptcha: Bool
        public let retryAfter: TimeInterval?
        
        public static let allowed = RateLimitResult(allowed: true, reason: nil, requiresCaptcha: false, retryAfter: nil)
        
        public static func denied(reason: String, retryAfter: TimeInterval? = nil) -> RateLimitResult {
            RateLimitResult(allowed: false, reason: reason, requiresCaptcha: false, retryAfter: retryAfter)
        }
        
        public static func requireCaptcha(reason: String) -> RateLimitResult {
            RateLimitResult(allowed: true, reason: reason, requiresCaptcha: true, retryAfter: nil)
        }
    }
    
 /// 黑名单条目
    public struct BlacklistEntry: Sendable, Codable {
        public let type: BlacklistType
        public let value: String
        public let reason: String
        public let expiresAt: Date?
        public let createdAt: Date
        
        public enum BlacklistType: String, Sendable, Codable {
            case ip
            case deviceFingerprint
            case identifier
            case emailDomain  // 一次性邮箱域名
        }
        
        public var isExpired: Bool {
            guard let expiresAt = expiresAt else { return false }
            return Date() > expiresAt
        }
    }
    
 // MARK: - 属性
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "RegistrationSecurity")
    private var config: RateLimitConfig
    
 /// 注册尝试记录（内存缓存，定期清理）
    private var attempts: [RegistrationAttempt] = []
    
 /// 黑名单
    private var ipBlacklist: [String: BlacklistEntry] = [:]
    private var deviceBlacklist: [String: BlacklistEntry] = [:]
    private var identifierBlacklist: [String: BlacklistEntry] = [:]
    
 /// 一次性邮箱域名黑名单
    private var disposableEmailDomains: Set<String> = [
        "tempmail.com", "guerrillamail.com", "10minutemail.com",
        "mailinator.com", "throwaway.email", "fakeinbox.com",
        "temp-mail.org", "dispostable.com", "maildrop.cc",
        "yopmail.com", "trashmail.com", "sharklasers.com"
    ]
    
 /// 全局请求计数器（用于全局限流）
    private var globalRequestTimestamps: [Date] = []
    
 /// 缓存清理计时器
    private var lastCleanupTime: Date = Date()
    private let cleanupInterval: TimeInterval = 300  // 5分钟清理一次
    
 // MARK: - 初始化
    
    private init(config: RateLimitConfig = .default) {
        self.config = config
        logger.info("RegistrationSecurityService 初始化完成")
    }
    
 /// 更新配置
    public func updateConfig(_ newConfig: RateLimitConfig) {
        self.config = newConfig
        logger.info("限流配置已更新")
    }
    
 // MARK: - 核心方法
    
 /// 检查是否允许注册
 /// - Parameter context: 注册上下文
 /// - Returns: 限流检查结果
    public func canRegister(context: RegistrationContext) async -> RateLimitResult {
 // 定期清理过期数据
        await cleanupIfNeeded()
        
 // 1. 检查黑名单
        if let blacklistResult = checkBlacklist(context: context) {
            logger.warning("注册被黑名单拦截: \(blacklistResult.reason ?? "未知原因")")
            return blacklistResult
        }
        
 // 2. 检查一次性邮箱
        if context.identifierType == .email {
            if let disposableResult = checkDisposableEmail(context.identifier) {
                logger.warning("一次性邮箱被拦截: \(context.identifier.prefix(3))***")
                return disposableResult
            }
        }
        
 // 3. 检查全局限流
        if let globalResult = checkGlobalRateLimit() {
            logger.warning("全局限流触发")
            return globalResult
        }
        
 // 4. 检查IP限流
        let ipAttempts = countRecentAttempts(byIP: context.ip, within: 60)  // 1分钟内
        if ipAttempts >= config.ipMaxPerMinute {
            logger.warning("IP限流触发: \(context.ip), 尝试次数: \(ipAttempts)")
            return .denied(reason: "操作过于频繁，请稍后再试", retryAfter: 60)
        }
        
 // 5. 检查设备限流
        let deviceAttempts = countRecentAttempts(byDevice: context.deviceFingerprint, within: 3600)  // 1小时内
        if deviceAttempts >= config.deviceMaxPerHour {
            logger.warning("设备限流触发: \(context.deviceFingerprint.prefix(8))..., 尝试次数: \(deviceAttempts)")
            return .denied(reason: "该设备注册次数过多，请稍后再试", retryAfter: 3600)
        }
        
 // 6. 检查账号限流
        let identifierAttempts = countRecentAttempts(byIdentifier: context.identifierHash, within: 86400)  // 24小时内
        if identifierAttempts >= config.identifierMaxPerDay {
            logger.warning("账号限流触发: \(context.identifierHash.prefix(8))..., 尝试次数: \(identifierAttempts)")
            return .denied(reason: "该账号注册尝试次数过多，请明天再试", retryAfter: 86400)
        }
        
 // 7. 检查是否需要行为验证
        let totalAttempts = max(ipAttempts, deviceAttempts)
        if totalAttempts >= config.captchaTriggerThreshold {
            logger.info("触发行为验证: IP尝试=\(ipAttempts), 设备尝试=\(deviceAttempts)")
            return .requireCaptcha(reason: "请完成安全验证")
        }
        
        return .allowed
    }
    
 /// 记录注册尝试
 /// - Parameters:
 /// - context: 注册上下文
 /// - success: 是否成功
 /// - failureReason: 失败原因
    public func recordAttempt(context: RegistrationContext, success: Bool, failureReason: String? = nil) async {
        let attempt = RegistrationAttempt(
            context: context,
            success: success,
            failureReason: failureReason
        )
        
        attempts.append(attempt)
        globalRequestTimestamps.append(Date())
        
        logger.info("注册尝试已记录: IP=\(context.ip), 设备=\(context.deviceFingerprint.prefix(8))..., 成功=\(success)")
        
 // 如果连续失败次数过多，自动加入黑名单
        await checkAndAutoBlacklist(context: context)
    }
    
 // MARK: - 输入清洗
    
 /// 清洗用户名输入
 /// - Parameter input: 原始输入
 /// - Returns: 清洗后的用户名
    public nonisolated func sanitizeUsername(_ input: String) -> String {
        var result = input
        
 // 1. 去除首尾空格
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
 // 2. 将连续空格替换为单个空格
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        
 // 3. 移除不可见字符
        result = result.filter { !$0.isNewline && $0 != "\t" && $0 != "\r" }
        
 // 4. 移除潜在的SQL注入/XSS字符
        let dangerousChars = CharacterSet(charactersIn: "<>\"'`;\\")
        result = result.unicodeScalars.filter { !dangerousChars.contains($0) }.map { String($0) }.joined()
        
 // 5. 转换为小写（用户名不区分大小写）
        result = result.lowercased()
        
        return result
    }
    
 /// 清洗密码输入（仅去除首尾空格，保留其他字符）
 /// - Parameter input: 原始输入
 /// - Returns: 清洗后的密码
    public nonisolated func sanitizePassword(_ input: String) -> String {
 // 密码只去除首尾空格，保留其他字符以支持强密码
        return input.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
 /// 清洗邮箱输入
 /// - Parameter input: 原始输入
 /// - Returns: 清洗后的邮箱
    public nonisolated func sanitizeEmail(_ input: String) -> String {
        var result = input
        
 // 1. 去除首尾空格
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        
 // 2. 转换为小写
        result = result.lowercased()
        
 // 3. 移除不可见字符
        result = result.filter { !$0.isNewline && $0 != "\t" && $0 != "\r" }
        
        return result
    }
    
 /// 清洗手机号输入
 /// - Parameter input: 原始输入
 /// - Returns: 清洗后的手机号
    public nonisolated func sanitizePhoneNumber(_ input: String) -> String {
        var result = input
        
 // 1. 去除所有空格和分隔符
        result = result.replacingOccurrences(of: " ", with: "")
        result = result.replacingOccurrences(of: "-", with: "")
        result = result.replacingOccurrences(of: "(", with: "")
        result = result.replacingOccurrences(of: ")", with: "")
        
 // 2. 保留数字和+号
        result = result.filter { $0.isNumber || $0 == "+" }
        
        return result
    }
    
 // MARK: - 黑名单管理
    
 /// 添加IP到黑名单
    public func addToIPBlacklist(ip: String, reason: String, duration: TimeInterval? = nil) {
        let entry = BlacklistEntry(
            type: .ip,
            value: ip,
            reason: reason,
            expiresAt: duration.map { Date().addingTimeInterval($0) },
            createdAt: Date()
        )
        ipBlacklist[ip] = entry
        logger.warning("IP已加入黑名单: \(ip), 原因: \(reason)")
    }
    
 /// 添加设备到黑名单
    public func addToDeviceBlacklist(fingerprint: String, reason: String, duration: TimeInterval? = nil) {
        let entry = BlacklistEntry(
            type: .deviceFingerprint,
            value: fingerprint,
            reason: reason,
            expiresAt: duration.map { Date().addingTimeInterval($0) },
            createdAt: Date()
        )
        deviceBlacklist[fingerprint] = entry
        logger.warning("设备已加入黑名单: \(fingerprint.prefix(8))..., 原因: \(reason)")
    }
    
 /// 添加账号标识到黑名单
    public func addToIdentifierBlacklist(identifierHash: String, reason: String, duration: TimeInterval? = nil) {
        let entry = BlacklistEntry(
            type: .identifier,
            value: identifierHash,
            reason: reason,
            expiresAt: duration.map { Date().addingTimeInterval($0) },
            createdAt: Date()
        )
        identifierBlacklist[identifierHash] = entry
        logger.warning("账号已加入黑名单: \(identifierHash.prefix(8))..., 原因: \(reason)")
    }
    
 /// 从黑名单移除
    public func removeFromBlacklist(type: BlacklistEntry.BlacklistType, value: String) {
        switch type {
        case .ip:
            ipBlacklist.removeValue(forKey: value)
        case .deviceFingerprint:
            deviceBlacklist.removeValue(forKey: value)
        case .identifier:
            identifierBlacklist.removeValue(forKey: value)
        case .emailDomain:
            disposableEmailDomains.remove(value)
        }
        logger.info("已从黑名单移除: \(type.rawValue) - \(value.prefix(8))...")
    }
    
 /// 添加一次性邮箱域名
    public func addDisposableEmailDomain(_ domain: String) {
        disposableEmailDomains.insert(domain.lowercased())
        logger.info("已添加一次性邮箱域名: \(domain)")
    }
    
 // MARK: - 统计信息
    
 /// 获取当前统计信息
    public func getStatistics() -> SecurityStatistics {
        let now = Date()
        let oneHourAgo = now.addingTimeInterval(-3600)
        let oneDayAgo = now.addingTimeInterval(-86400)
        
        let recentAttempts = attempts.filter { $0.createdAt > oneHourAgo }
        let dailyAttempts = attempts.filter { $0.createdAt > oneDayAgo }
        
        return SecurityStatistics(
            totalAttempts: attempts.count,
            recentAttempts: recentAttempts.count,
            dailyAttempts: dailyAttempts.count,
            successfulAttempts: attempts.filter { $0.success }.count,
            failedAttempts: attempts.filter { !$0.success }.count,
            blacklistedIPs: ipBlacklist.count,
            blacklistedDevices: deviceBlacklist.count,
            blacklistedIdentifiers: identifierBlacklist.count,
            disposableEmailDomains: disposableEmailDomains.count
        )
    }
    
    public struct SecurityStatistics: Sendable {
        public let totalAttempts: Int
        public let recentAttempts: Int  // 最近1小时
        public let dailyAttempts: Int   // 最近24小时
        public let successfulAttempts: Int
        public let failedAttempts: Int
        public let blacklistedIPs: Int
        public let blacklistedDevices: Int
        public let blacklistedIdentifiers: Int
        public let disposableEmailDomains: Int
    }
    
 // MARK: - 私有方法
    
 /// 检查黑名单
    private func checkBlacklist(context: RegistrationContext) -> RateLimitResult? {
 // 检查IP黑名单
        if let entry = ipBlacklist[context.ip], !entry.isExpired {
            return .denied(reason: "您的IP已被限制注册", retryAfter: entry.expiresAt?.timeIntervalSinceNow)
        }
        
 // 检查设备黑名单
        if let entry = deviceBlacklist[context.deviceFingerprint], !entry.isExpired {
            return .denied(reason: "该设备已被限制注册", retryAfter: entry.expiresAt?.timeIntervalSinceNow)
        }
        
 // 检查账号黑名单
        if let entry = identifierBlacklist[context.identifierHash], !entry.isExpired {
            return .denied(reason: "该账号已被限制注册", retryAfter: entry.expiresAt?.timeIntervalSinceNow)
        }
        
        return nil
    }
    
 /// 检查一次性邮箱
    private func checkDisposableEmail(_ email: String) -> RateLimitResult? {
        let domain = email.components(separatedBy: "@").last?.lowercased() ?? ""
        if disposableEmailDomains.contains(domain) {
            return .denied(reason: "不支持使用临时邮箱注册")
        }
        return nil
    }
    
 /// 检查全局限流
    private func checkGlobalRateLimit() -> RateLimitResult? {
        let now = Date()
        let oneSecondAgo = now.addingTimeInterval(-1)
        
 // 清理旧的时间戳
        globalRequestTimestamps = globalRequestTimestamps.filter { $0 > oneSecondAgo }
        
        if globalRequestTimestamps.count >= config.globalMaxPerSecond {
            return .denied(reason: "服务器繁忙，请稍后再试", retryAfter: 1)
        }
        
        return nil
    }
    
 /// 统计指定IP最近的尝试次数
    private func countRecentAttempts(byIP ip: String, within seconds: TimeInterval) -> Int {
        let threshold = Date().addingTimeInterval(-seconds)
        return attempts.filter { $0.context.ip == ip && $0.createdAt > threshold }.count
    }
    
 /// 统计指定设备最近的尝试次数
    private func countRecentAttempts(byDevice fingerprint: String, within seconds: TimeInterval) -> Int {
        let threshold = Date().addingTimeInterval(-seconds)
        return attempts.filter { $0.context.deviceFingerprint == fingerprint && $0.createdAt > threshold }.count
    }
    
 /// 统计指定账号最近的尝试次数
    private func countRecentAttempts(byIdentifier identifierHash: String, within seconds: TimeInterval) -> Int {
        let threshold = Date().addingTimeInterval(-seconds)
        return attempts.filter { $0.context.identifierHash == identifierHash && $0.createdAt > threshold }.count
    }
    
 /// 检查并自动加入黑名单（连续失败过多）
    private func checkAndAutoBlacklist(context: RegistrationContext) async {
        let recentFailures = attempts.filter {
            !$0.success &&
            $0.context.ip == context.ip &&
            $0.createdAt > Date().addingTimeInterval(-3600)  // 1小时内
        }.count
        
 // 连续失败10次，自动封禁IP 1小时
        if recentFailures >= 10 {
            addToIPBlacklist(ip: context.ip, reason: "连续注册失败过多", duration: 3600)
        }
        
 // 连续失败20次，封禁设备24小时
        let deviceFailures = attempts.filter {
            !$0.success &&
            $0.context.deviceFingerprint == context.deviceFingerprint &&
            $0.createdAt > Date().addingTimeInterval(-86400)
        }.count
        
        if deviceFailures >= 20 {
            addToDeviceBlacklist(fingerprint: context.deviceFingerprint, reason: "设备注册失败过多", duration: 86400)
        }
    }
    
 /// 定期清理过期数据
    private func cleanupIfNeeded() async {
        let now = Date()
        guard now.timeIntervalSince(lastCleanupTime) > cleanupInterval else { return }
        
        lastCleanupTime = now
        
 // 清理24小时前的尝试记录
        let cutoff = now.addingTimeInterval(-86400)
        attempts = attempts.filter { $0.createdAt > cutoff }
        
 // 清理过期的黑名单条目
        ipBlacklist = ipBlacklist.filter { !$0.value.isExpired }
        deviceBlacklist = deviceBlacklist.filter { !$0.value.isExpired }
        identifierBlacklist = identifierBlacklist.filter { !$0.value.isExpired }
        
 // 清理全局请求时间戳
        globalRequestTimestamps = globalRequestTimestamps.filter { $0 > now.addingTimeInterval(-60) }
        
        logger.info("安全服务缓存已清理")
    }
}

// MARK: - 输入校验扩展

@available(macOS 14.0, *)
extension RegistrationSecurityService {
    
 /// 用户名校验规则
    public struct UsernameValidation: Sendable {
        public let minLength: Int
        public let maxLength: Int
        public let allowedCharacters: CharacterSet
        public let reservedNames: Set<String>
        
        public static let `default` = UsernameValidation(
            minLength: 4,
            maxLength: 20,
            allowedCharacters: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")),
            reservedNames: ["admin", "root", "system", "support", "help", "test", "null", "undefined"]
        )
    }
    
 /// 密码强度级别
    public enum PasswordStrength: Int, Sendable, Comparable {
        case weak = 1
        case medium = 2
        case strong = 3
        case veryStrong = 4
        
        public static func < (lhs: PasswordStrength, rhs: PasswordStrength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
        
        public var description: String {
            switch self {
            case .weak: return "弱"
            case .medium: return "中等"
            case .strong: return "强"
            case .veryStrong: return "非常强"
            }
        }
    }
    
 /// 验证用户名
 /// - Parameters:
 /// - username: 用户名
 /// - rules: 校验规则
 /// - Returns: 验证结果
    public nonisolated func validateUsername(_ username: String, rules: UsernameValidation = .default) -> (valid: Bool, error: String?) {
        let sanitized = sanitizeUsername(username)
        
 // 长度检查
        if sanitized.count < rules.minLength {
            return (false, "用户名至少需要\(rules.minLength)个字符")
        }
        
        if sanitized.count > rules.maxLength {
            return (false, "用户名最多\(rules.maxLength)个字符")
        }
        
 // 字符检查
        let invalidChars = sanitized.unicodeScalars.filter { !rules.allowedCharacters.contains($0) }
        if !invalidChars.isEmpty {
            return (false, "用户名只能包含字母、数字和下划线")
        }
        
 // 保留名检查
        if rules.reservedNames.contains(sanitized) {
            return (false, "该用户名已被保留")
        }
        
 // 不能以数字开头
        if let first = sanitized.first, first.isNumber {
            return (false, "用户名不能以数字开头")
        }
        
        return (true, nil)
    }
    
 /// 评估密码强度
 /// - Parameter password: 密码
 /// - Returns: 密码强度
    public nonisolated func evaluatePasswordStrength(_ password: String) -> PasswordStrength {
        var score = 0
        
 // 长度评分
        if password.count >= 8 { score += 1 }
        if password.count >= 12 { score += 1 }
        if password.count >= 16 { score += 1 }
        
 // 复杂度评分
        if password.contains(where: { $0.isLowercase }) { score += 1 }
        if password.contains(where: { $0.isUppercase }) { score += 1 }
        if password.contains(where: { $0.isNumber }) { score += 1 }
        if password.contains(where: { "!@#$%^&*()_+-=[]{}|;':\",./<>?".contains($0) }) { score += 1 }
        
 // 映射到强度级别
        switch score {
        case 0...2: return .weak
        case 3...4: return .medium
        case 5...6: return .strong
        default: return .veryStrong
        }
    }
    
 /// 验证密码（强度+格式）
 /// - Parameters:
 /// - password: 密码
 /// - minimumStrength: 最低强度要求
 /// - Returns: 验证结果
    public nonisolated func validatePassword(_ password: String, minimumStrength: PasswordStrength = .medium) -> (valid: Bool, strength: PasswordStrength, error: String?) {
        let sanitized = sanitizePassword(password)
        
 // 最小长度检查
        if sanitized.count < 8 {
            return (false, .weak, "密码至少需要8个字符")
        }
        
 // 最大长度检查
        if sanitized.count > 128 {
            return (false, .weak, "密码最多128个字符")
        }
        
        let strength = evaluatePasswordStrength(sanitized)
        
        if strength < minimumStrength {
            var requirements: [String] = []
            if !sanitized.contains(where: { $0.isUppercase }) {
                requirements.append("大写字母")
            }
            if !sanitized.contains(where: { $0.isLowercase }) {
                requirements.append("小写字母")
            }
            if !sanitized.contains(where: { $0.isNumber }) {
                requirements.append("数字")
            }
            if !sanitized.contains(where: { "!@#$%^&*()_+-=[]{}|;':\",./<>?".contains($0) }) {
                requirements.append("特殊字符")
            }
            
            let requirementText = requirements.isEmpty ? "" : "，建议添加：\(requirements.joined(separator: "、"))"
            return (false, strength, "密码强度不足\(requirementText)")
        }
        
        return (true, strength, nil)
    }
    
 /// 验证邮箱格式
 /// - Parameter email: 邮箱
 /// - Returns: 验证结果
    public nonisolated func validateEmail(_ email: String) -> (valid: Bool, error: String?) {
        let sanitized = sanitizeEmail(email)
        
 // 基础格式检查
        let emailRegex = "^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)
        
        if !emailPredicate.evaluate(with: sanitized) {
            return (false, "请输入有效的邮箱地址")
        }
        
 // 长度检查
        if sanitized.count > 254 {
            return (false, "邮箱地址过长")
        }
        
        return (true, nil)
    }
    
 /// 验证手机号格式（支持国际号码）
 /// - Parameter phone: 手机号
 /// - Returns: 验证结果
    public nonisolated func validatePhoneNumber(_ phone: String) -> (valid: Bool, error: String?) {
        let sanitized = sanitizePhoneNumber(phone)
        
 // E.164 格式检查（国际手机号）
        let internationalRegex = "^\\+[1-9]\\d{1,14}$"
        let internationalPredicate = NSPredicate(format: "SELF MATCHES %@", internationalRegex)
        
 // 中国大陆手机号格式
        let chinaRegex = "^1[3-9]\\d{9}$"
        let chinaPredicate = NSPredicate(format: "SELF MATCHES %@", chinaRegex)
        
        if internationalPredicate.evaluate(with: sanitized) || chinaPredicate.evaluate(with: sanitized) {
            return (true, nil)
        }
        
        return (false, "请输入有效的手机号码（支持国际号码，格式：+国家代码手机号）")
    }
}

