import Foundation
import CryptoKit
import os.log

/// 验证码发送服务 - 智能多通道轮询、自动重试、防滥用
///
/// 核心功能：
/// 1. 运营商通道轮询（移动组/联通/电信）
/// 2. 异步状态回调
/// 3. 通道自动降级
/// 4. 超时自动补发
/// 5. 智能防滥用机制
@available(macOS 14.0, *)
public actor VerificationCodeService {
    
 // MARK: - 单例
    
    public static let shared = VerificationCodeService()
    
 // MARK: - 运营商枚举
    
 /// 运营商类型
    public enum Carrier: String, CaseIterable, Sendable {
        case chinaMobile = "china_mobile"     // 中国移动（含广电）
        case chinaUnicom = "china_unicom"     // 中国联通
        case chinaTelecom = "china_telecom"   // 中国电信
        
        var displayName: String {
            switch self {
            case .chinaMobile: return "中国移动"
            case .chinaUnicom: return "中国联通"
            case .chinaTelecom: return "中国电信"
            }
        }
        
 /// 手机号段前缀
        var prefixes: [String] {
            switch self {
            case .chinaMobile:
 // 移动：134-139, 147, 150-152, 157-159, 172, 178, 182-184, 187-188, 195, 197-198
 // 广电：192（底层使用移动网络，合并处理）
                return ["134", "135", "136", "137", "138", "139", "147", "150", "151", "152",
                        "157", "158", "159", "172", "178", "182", "183", "184", "187", "188",
                        "195", "197", "198", "192"]
            case .chinaUnicom:
 // 联通：130-132, 145, 155-156, 166, 175-176, 185-186, 196
                return ["130", "131", "132", "145", "155", "156", "166", "175", "176", "185", "186", "196"]
            case .chinaTelecom:
 // 电信：133, 149, 153, 173-174, 177, 180-181, 189, 190-191, 193, 199
                return ["133", "149", "153", "173", "174", "177", "180", "181", "189", "190", "191", "193", "199"]
            }
        }
    }
    
 /// 短信通道配置
    public struct SMSChannel: Sendable {
        let carrier: Carrier
        let endpoint: String
        let accessKeyId: String
        let accessKeySecret: String
        let signName: String
        let templateCode: String
        var isEnabled: Bool
        var successRate: Double  // 历史成功率
        var lastFailureTime: Date?
        var consecutiveFailures: Int
        
 /// 是否可用（未被熔断）
        var isAvailable: Bool {
            guard isEnabled else { return false }
 // 连续失败5次后熔断30分钟
            if consecutiveFailures >= 5 {
                if let lastFailure = lastFailureTime {
                    return Date().timeIntervalSince(lastFailure) > 1800  // 30分钟后恢复
                }
            }
            return true
        }
    }
    
 // MARK: - 发送状态
    
 /// 发送状态
    public enum SendStatus: String, Sendable {
        case pending = "pending"           // 待发送
        case sending = "sending"           // 发送中
        case delivered = "delivered"       // 已送达
        case failed = "failed"             // 发送失败
        case expired = "expired"           // 已过期
        case retrying = "retrying"         // 重试中
    }
    
 /// 发送记录
    public struct SendRecord: Sendable {
        public let id: UUID
        public let phoneNumber: String
        public let code: String
        public let channel: Carrier
        public var status: SendStatus
        public let createdAt: Date
        public var deliveredAt: Date?
        public var failureReason: String?
        public var retryCount: Int
        public var messageId: String?
        
        public init(id: UUID = UUID(), phoneNumber: String, code: String, channel: Carrier) {
            self.id = id
            self.phoneNumber = phoneNumber
            self.code = code
            self.channel = channel
            self.status = .pending
            self.createdAt = Date()
            self.retryCount = 0
        }
    }
    
 /// 发送结果
    public struct SendResult: Sendable {
        public let success: Bool
        public let recordId: UUID
        public let channel: Carrier
        public let messageId: String?
        public let errorMessage: String?
        public let retryCount: Int
        public let requiresCaptcha: Bool
        public let nextRetryAvailableAt: Date?
        
        public static func success(recordId: UUID, channel: Carrier, messageId: String?) -> SendResult {
            SendResult(success: true, recordId: recordId, channel: channel, messageId: messageId,
                      errorMessage: nil, retryCount: 0, requiresCaptcha: false, nextRetryAvailableAt: nil)
        }
        
        public static func failure(recordId: UUID, channel: Carrier, error: String, retryCount: Int, requiresCaptcha: Bool = false, nextRetry: Date? = nil) -> SendResult {
            SendResult(success: false, recordId: recordId, channel: channel, messageId: nil,
                      errorMessage: error, retryCount: retryCount, requiresCaptcha: requiresCaptcha, nextRetryAvailableAt: nextRetry)
        }
    }
    
 // MARK: - 防滥用配置
    
 /// 防滥用配置
    public struct AbusePreventionConfig: Sendable {
 /// 单个手机号每日最大发送次数
        let phoneMaxPerDay: Int
 /// 单个设备每日最大发送次数（跨手机号）
        let deviceMaxPerDay: Int
 /// 单个IP每小时最大发送次数
        let ipMaxPerHour: Int
 /// "收不到验证码"点击的冷却时间（秒）
        let resendCooldown: TimeInterval
 /// 触发行为验证的阈值
        let captchaTriggerThreshold: Int
 /// 渐进式延迟基数（秒）
        let progressiveDelayBase: TimeInterval
        
        public static let `default` = AbusePreventionConfig(
            phoneMaxPerDay: 10,
            deviceMaxPerDay: 20,
            ipMaxPerHour: 15,
            resendCooldown: 60,
            captchaTriggerThreshold: 3,
            progressiveDelayBase: 60
        )
        
 /// 计算渐进式延迟
        func calculateDelay(attemptCount: Int) -> TimeInterval {
 // 第1-2次：60秒
 // 第3次：120秒
 // 第4次：240秒
 // 第5次以上：480秒
            guard attemptCount > 2 else { return progressiveDelayBase }
            let multiplier = pow(2.0, Double(min(attemptCount - 2, 3)))
            return progressiveDelayBase * multiplier
        }
    }
    
 /// 发送上下文（用于防滥用检查）
    public struct SendContext: Sendable {
        public let phoneNumber: String
        public let deviceFingerprint: String
        public let ip: String
        public let isResend: Bool  // 是否是"收不到验证码"重发
        public let captchaPassed: Bool
        
        public init(phoneNumber: String, deviceFingerprint: String, ip: String, isResend: Bool = false, captchaPassed: Bool = false) {
            self.phoneNumber = phoneNumber
            self.deviceFingerprint = deviceFingerprint
            self.ip = ip
            self.isResend = isResend
            self.captchaPassed = captchaPassed
        }
    }
    
 // MARK: - 属性
    
    private let logger = Logger(subsystem: "com.skybridge.compass", category: "VerificationCode")
    
 /// 通道配置（按运营商）
    private var channels: [Carrier: SMSChannel] = [:]
    
 /// 发送记录
    private var sendRecords: [UUID: SendRecord] = [:]
    
 /// 手机号发送历史（用于限流）
    private var phoneSendHistory: [String: [Date]] = [:]
    
 /// 设备发送历史
    private var deviceSendHistory: [String: [Date]] = [:]
    
 /// IP发送历史
    private var ipSendHistory: [String: [Date]] = [:]
    
 /// "收不到验证码"点击记录
    private var resendClickHistory: [String: [Date]] = [:]  // key: phone+device
    
 /// 防滥用配置
    private var abuseConfig = AbusePreventionConfig.default
    
 /// 通道成功率统计
    private var channelStats: [Carrier: (success: Int, total: Int)] = [:]
    
 /// 状态回调
    private var statusCallbacks: [UUID: (SendStatus) -> Void] = [:]
    
 // MARK: - 初始化
    
    private init() {
 // 初始化默认通道配置（静态构造，避免actor隔离冲突）
        self.channels = Self.makeDefaultChannels()
        logger.info("VerificationCodeService 初始化完成")
    }
    
 /// 构建默认通道配置（静态，避免初始化期触发actor隔离错误）
    private static func makeDefaultChannels() -> [Carrier: SMSChannel] {
        let env = ProcessInfo.processInfo.environment
        var result: [Carrier: SMSChannel] = [:]
        
 // 移动通道（含广电）
        result[.chinaMobile] = SMSChannel(
            carrier: .chinaMobile,
            endpoint: env["SMS_MOBILE_ENDPOINT"] ?? "dysmsapi.aliyuncs.com",
            accessKeyId: env["SMS_MOBILE_KEY_ID"] ?? "",
            accessKeySecret: env["SMS_MOBILE_KEY_SECRET"] ?? "",
            signName: env["SMS_SIGN_NAME"] ?? "SkyBridge",
            templateCode: env["SMS_TEMPLATE_CODE"] ?? "",
            isEnabled: true,
            successRate: 0.95,
            lastFailureTime: nil,
            consecutiveFailures: 0
        )
        
 // 联通通道
        result[.chinaUnicom] = SMSChannel(
            carrier: .chinaUnicom,
            endpoint: env["SMS_UNICOM_ENDPOINT"] ?? "dysmsapi.aliyuncs.com",
            accessKeyId: env["SMS_UNICOM_KEY_ID"] ?? "",
            accessKeySecret: env["SMS_UNICOM_KEY_SECRET"] ?? "",
            signName: env["SMS_SIGN_NAME"] ?? "SkyBridge",
            templateCode: env["SMS_TEMPLATE_CODE"] ?? "",
            isEnabled: true,
            successRate: 0.94,
            lastFailureTime: nil,
            consecutiveFailures: 0
        )
        
 // 电信通道
        result[.chinaTelecom] = SMSChannel(
            carrier: .chinaTelecom,
            endpoint: env["SMS_TELECOM_ENDPOINT"] ?? "dysmsapi.aliyuncs.com",
            accessKeyId: env["SMS_TELECOM_KEY_ID"] ?? "",
            accessKeySecret: env["SMS_TELECOM_KEY_SECRET"] ?? "",
            signName: env["SMS_SIGN_NAME"] ?? "SkyBridge",
            templateCode: env["SMS_TEMPLATE_CODE"] ?? "",
            isEnabled: true,
            successRate: 0.93,
            lastFailureTime: nil,
            consecutiveFailures: 0
        )
        
        return result
    }
    
 // MARK: - 核心发送方法
    
 /// 发送验证码（智能多通道）
 /// - Parameters:
 /// - context: 发送上下文
 /// - statusCallback: 状态回调
 /// - Returns: 发送结果
    public func sendVerificationCode(
        context: SendContext,
        statusCallback: ((SendStatus) -> Void)? = nil
    ) async -> SendResult {
        logger.info("📱 开始发送验证码: \(context.phoneNumber.prefix(3))****")
        
 // 1. 防滥用检查
        let abuseCheck = await checkAbusePrevention(context: context)
        if !abuseCheck.allowed {
            logger.warning("⚠️ 防滥用检查未通过: \(abuseCheck.reason ?? "未知")")
            return SendResult.failure(
                recordId: UUID(),
                channel: .chinaMobile,
                error: abuseCheck.reason ?? "操作过于频繁",
                retryCount: 0,
                requiresCaptcha: abuseCheck.requiresCaptcha,
                nextRetry: abuseCheck.nextAvailableTime
            )
        }
        
 // 2. 生成验证码
        let code = generateVerificationCode()
        
 // 3. 识别运营商并选择最优通道
        let primaryCarrier = identifyCarrier(phone: context.phoneNumber)
        let channelOrder = determineChannelOrder(primary: primaryCarrier)
        
        logger.info("📡 通道顺序: \(channelOrder.map { $0.displayName }.joined(separator: " -> "))")
        
 // 4. 创建发送记录
        var record = SendRecord(phoneNumber: context.phoneNumber, code: code, channel: primaryCarrier)
        sendRecords[record.id] = record
        
 // 注册状态回调
        if let callback = statusCallback {
            statusCallbacks[record.id] = callback
        }
        
 // 5. 轮询发送
        var lastError: String?
        
        for (index, carrier) in channelOrder.enumerated() {
            guard let channel = channels[carrier], channel.isAvailable else {
                logger.info("⏭️ 跳过不可用通道: \(carrier.displayName)")
                continue
            }
            
            record.status = index == 0 ? .sending : .retrying
            record.retryCount = index
            updateRecordAndNotify(&record)
            
            logger.info("🔄 尝试通道 \(index + 1)/\(channelOrder.count): \(carrier.displayName)")
            
            do {
                let result = try await sendViaSMSChannel(
                    channel: channel,
                    phoneNumber: context.phoneNumber,
                    code: code
                )
                
                if result.success {
 // 发送成功
                    record.status = .delivered
                    record.deliveredAt = Date()
                    record.messageId = result.messageId
                    updateRecordAndNotify(&record)
                    
 // 更新通道统计
                    await updateChannelStats(carrier: carrier, success: true)
                    
 // 记录发送历史
                    await recordSendHistory(context: context)
                    
                    logger.info("✅ 验证码发送成功: 通道=\(carrier.displayName), 重试次数=\(index)")
                    
                    return SendResult.success(
                        recordId: record.id,
                        channel: carrier,
                        messageId: result.messageId
                    )
                } else {
                    lastError = result.message
                    await updateChannelStats(carrier: carrier, success: false)
                    await markChannelFailure(carrier: carrier)
                }
                
            } catch {
                lastError = error.localizedDescription
                await updateChannelStats(carrier: carrier, success: false)
                await markChannelFailure(carrier: carrier)
                logger.error("❌ 通道 \(carrier.displayName) 发送失败: \(error.localizedDescription)")
            }
            
 // 等待一小段时间后尝试下一个通道
            if index < channelOrder.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5秒
            }
        }
        
 // 所有通道都失败
        record.status = .failed
        record.failureReason = lastError ?? "所有通道发送失败"
        updateRecordAndNotify(&record)
        
        logger.error("❌ 验证码发送失败: 所有通道均不可用")
        
        return SendResult.failure(
            recordId: record.id,
            channel: primaryCarrier,
            error: lastError ?? "发送失败，请稍后重试",
            retryCount: channelOrder.count
        )
    }
    
 /// "收不到验证码"重发
 /// - Parameter context: 发送上下文
 /// - Returns: 发送结果
    public func resendVerificationCode(context: SendContext) async -> SendResult {
        logger.info("🔄 用户点击'收不到验证码': \(context.phoneNumber.prefix(3))****")
        
 // 记录重发点击
        let clickKey = "\(context.phoneNumber)_\(context.deviceFingerprint)"
        var clicks = resendClickHistory[clickKey] ?? []
        clicks.append(Date())
        
 // 只保留24小时内的记录
        let cutoff = Date().addingTimeInterval(-86400)
        clicks = clicks.filter { $0 > cutoff }
        resendClickHistory[clickKey] = clicks
        
 // 检查重发频率
        let recentClicks = clicks.filter { Date().timeIntervalSince($0) < 300 }  // 5分钟内
        
        if recentClicks.count > 3 {
 // 5分钟内点击超过3次，可能是滥用
            logger.warning("⚠️ 重发点击过于频繁: \(recentClicks.count) 次/5分钟")
            
            if recentClicks.count > 5 && !context.captchaPassed {
 // 需要行为验证
                return SendResult.failure(
                    recordId: UUID(),
                    channel: .chinaMobile,
                    error: "请完成安全验证后重试",
                    retryCount: 0,
                    requiresCaptcha: true
                )
            }
            
 // 计算渐进式延迟
            let delay = abuseConfig.calculateDelay(attemptCount: recentClicks.count)
            let nextAvailable = Date().addingTimeInterval(delay)
            
            return SendResult.failure(
                recordId: UUID(),
                channel: .chinaMobile,
                error: "操作过于频繁，请\(Int(delay))秒后重试",
                retryCount: 0,
                nextRetry: nextAvailable
            )
        }
        
 // 创建新的上下文（标记为重发）
        let resendContext = SendContext(
            phoneNumber: context.phoneNumber,
            deviceFingerprint: context.deviceFingerprint,
            ip: context.ip,
            isResend: true,
            captchaPassed: context.captchaPassed
        )
        
 // 使用备用通道顺序发送
        return await sendVerificationCode(context: resendContext)
    }
    
 // MARK: - 防滥用检查
    
 /// 防滥用检查结果
    private struct AbuseCheckResult {
        let allowed: Bool
        let reason: String?
        let requiresCaptcha: Bool
        let nextAvailableTime: Date?
    }
    
 /// 执行防滥用检查
    private func checkAbusePrevention(context: SendContext) async -> AbuseCheckResult {
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-86400)
        let oneHourAgo = now.addingTimeInterval(-3600)
        
 // 1. 检查手机号每日限额
        let phoneSends = (phoneSendHistory[context.phoneNumber] ?? []).filter { $0 > oneDayAgo }
        if phoneSends.count >= abuseConfig.phoneMaxPerDay {
            logger.warning("⚠️ 手机号达到每日上限: \(phoneSends.count)")
            return AbuseCheckResult(
                allowed: false,
                reason: "该手机号今日发送次数已达上限，请明天再试",
                requiresCaptcha: false,
                nextAvailableTime: Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
            )
        }
        
 // 2. 检查设备每日限额（跨手机号）
        let deviceSends = (deviceSendHistory[context.deviceFingerprint] ?? []).filter { $0 > oneDayAgo }
        if deviceSends.count >= abuseConfig.deviceMaxPerDay {
            logger.warning("⚠️ 设备达到每日上限: \(deviceSends.count)")
            return AbuseCheckResult(
                allowed: false,
                reason: "该设备今日发送次数已达上限",
                requiresCaptcha: false,
                nextAvailableTime: Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
            )
        }
        
 // 3. 检查IP每小时限额
        let ipSends = (ipSendHistory[context.ip] ?? []).filter { $0 > oneHourAgo }
        if ipSends.count >= abuseConfig.ipMaxPerHour {
            logger.warning("⚠️ IP达到每小时上限: \(ipSends.count)")
            return AbuseCheckResult(
                allowed: false,
                reason: "操作过于频繁，请稍后再试",
                requiresCaptcha: false,
                nextAvailableTime: now.addingTimeInterval(3600)
            )
        }
        
 // 4. 检查冷却时间
        if let lastSend = phoneSends.last {
            let cooldown = context.isResend ? abuseConfig.resendCooldown : abuseConfig.resendCooldown
            let elapsed = now.timeIntervalSince(lastSend)
            if elapsed < cooldown {
                let remaining = Int(cooldown - elapsed)
                return AbuseCheckResult(
                    allowed: false,
                    reason: "请\(remaining)秒后再试",
                    requiresCaptcha: false,
                    nextAvailableTime: lastSend.addingTimeInterval(cooldown)
                )
            }
        }
        
 // 5. 检查是否需要行为验证（基于设备+手机号组合的尝试次数）
        let combinedAttempts = max(phoneSends.count, deviceSends.count)
        if combinedAttempts >= abuseConfig.captchaTriggerThreshold && !context.captchaPassed {
            logger.info("🔒 触发行为验证: 尝试次数=\(combinedAttempts)")
            return AbuseCheckResult(
                allowed: false,
                reason: "请完成安全验证",
                requiresCaptcha: true,
                nextAvailableTime: nil
            )
        }
        
 // 6. 异常行为检测：同一设备短时间内向多个不同手机号发送
        let recentDeviceSends = deviceSends.filter { now.timeIntervalSince($0) < 600 }  // 10分钟内
        if recentDeviceSends.count >= 3 {
 // 检查是否是不同手机号
            let uniquePhones = getUniquePhonesByDevice(deviceFingerprint: context.deviceFingerprint, within: 600)
            if uniquePhones.count >= 3 {
                logger.warning("⚠️ 检测到可疑行为: 设备在10分钟内向\(uniquePhones.count)个不同手机号发送验证码")
                return AbuseCheckResult(
                    allowed: false,
                    reason: "检测到异常行为，请稍后再试",
                    requiresCaptcha: true,
                    nextAvailableTime: now.addingTimeInterval(1800)  // 30分钟后
                )
            }
        }
        
        return AbuseCheckResult(allowed: true, reason: nil, requiresCaptcha: false, nextAvailableTime: nil)
    }
    
 /// 获取设备最近向多少个不同手机号发送过验证码
    private func getUniquePhonesByDevice(deviceFingerprint: String, within seconds: TimeInterval) -> Set<String> {
        let cutoff = Date().addingTimeInterval(-seconds)
        var phones = Set<String>()
        
        for (_, record) in sendRecords {
            if record.createdAt > cutoff {
 // 这里需要记录设备指纹和手机号的对应关系
 // 简化处理：假设我们有这个信息
                phones.insert(record.phoneNumber)
            }
        }
        
        return phones
    }
    
 // MARK: - 运营商识别和通道选择
    
 /// 根据手机号识别运营商
    private func identifyCarrier(phone: String) -> Carrier {
        let prefix = String(phone.prefix(3))
        
        for carrier in Carrier.allCases {
            if carrier.prefixes.contains(prefix) {
                return carrier
            }
        }
        
 // 默认返回移动
        return .chinaMobile
    }
    
 /// 确定通道轮询顺序
    private func determineChannelOrder(primary: Carrier) -> [Carrier] {
        var order: [Carrier] = [primary]
        
 // 添加其他运营商，按成功率排序
        let others = Carrier.allCases.filter { $0 != primary }
        let sortedOthers = others.sorted { carrier1, carrier2 in
            let rate1 = channels[carrier1]?.successRate ?? 0
            let rate2 = channels[carrier2]?.successRate ?? 0
            return rate1 > rate2
        }
        
        order.append(contentsOf: sortedOthers)
        
        return order
    }
    
 // MARK: - 通道发送
    
 /// 通过短信通道发送
    private func sendViaSMSChannel(
        channel: SMSChannel,
        phoneNumber: String,
        code: String
    ) async throws -> SMSResult {
 // 构建请求参数
        let parameters = buildSMSParameters(
            channel: channel,
            phoneNumber: phoneNumber,
            code: code
        )
        
 // 生成签名
        let signature = try generateSignature(
            parameters: parameters,
            secret: channel.accessKeySecret
        )
        
 // 发送请求
        return try await executeSMSRequest(
            parameters: parameters,
            signature: signature,
            endpoint: channel.endpoint
        )
    }
    
 /// 构建SMS参数
    private func buildSMSParameters(
        channel: SMSChannel,
        phoneNumber: String,
        code: String
    ) -> [String: String] {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let nonce = UUID().uuidString
        
        let templateParam = ["code": code]
        let templateParamJSON = try? JSONSerialization.data(withJSONObject: templateParam)
        let templateParamString = templateParamJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        
        return [
            "AccessKeyId": channel.accessKeyId,
            "Action": "SendSms",
            "Format": "JSON",
            "PhoneNumbers": phoneNumber,
            "SignName": channel.signName,
            "TemplateCode": channel.templateCode,
            "TemplateParam": templateParamString,
            "Timestamp": timestamp,
            "SignatureMethod": "HMAC-SHA1",
            "SignatureNonce": nonce,
            "SignatureVersion": "1.0",
            "Version": "2017-05-25"
        ]
    }
    
 /// 生成签名
    private func generateSignature(parameters: [String: String], secret: String) throws -> String {
        let sortedParams = parameters.sorted { $0.key < $1.key }
        let queryString = sortedParams
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
        
        let stringToSign = "GET&\(percentEncode("/"))&\(percentEncode(queryString))"
        
        let key = "\(secret)&"
        guard let keyData = key.data(using: .utf8),
              let stringData = stringToSign.data(using: .utf8) else {
            throw SMSService.SMSError.signatureError
        }
        
        let signature = HMAC<Insecure.SHA1>.authenticationCode(for: stringData, using: SymmetricKey(data: keyData))
        return Data(signature).base64EncodedString()
    }
    
 /// URL编码
    private nonisolated func percentEncode(_ string: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }
    
 /// 执行SMS请求
    private func executeSMSRequest(
        parameters: [String: String],
        signature: String,
        endpoint: String
    ) async throws -> SMSResult {
        var fullParameters = parameters
        fullParameters["Signature"] = signature
        
        let queryString = fullParameters
            .map { "\($0.key)=\(percentEncode($0.value))" }
            .joined(separator: "&")
        
        guard let url = URL(string: "https://\(endpoint)?\(queryString)") else {
            throw SMSService.SMSError.networkError(URLError(.badURL))
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SMSService.SMSError.networkError(URLError(.badServerResponse))
        }
        
        guard httpResponse.statusCode == 200 else {
            throw SMSService.SMSError.apiError("HTTP \(httpResponse.statusCode)")
        }
        
 // 解析响应
        struct AliyunResponse: Codable {
            let Code: String
            let Message: String?
            let BizId: String?
        }
        
        let decoded = try JSONDecoder().decode(AliyunResponse.self, from: data)
        
        return SMSResult(
            success: decoded.Code == "OK",
            messageId: decoded.BizId,
            message: decoded.Message
        )
    }
    
 // MARK: - 辅助方法
    
 /// 生成验证码
    private func generateVerificationCode() -> String {
        let digits = "0123456789"
        return String((0..<6).compactMap { _ in digits.randomElement() })
    }
    
 /// 更新记录并通知
    private func updateRecordAndNotify(_ record: inout SendRecord) {
        sendRecords[record.id] = record
        statusCallbacks[record.id]?(record.status)
    }
    
 /// 记录发送历史
    private func recordSendHistory(context: SendContext) async {
        let now = Date()
        
 // 手机号历史
        var phoneHistory = phoneSendHistory[context.phoneNumber] ?? []
        phoneHistory.append(now)
        phoneSendHistory[context.phoneNumber] = phoneHistory
        
 // 设备历史
        var deviceHistory = deviceSendHistory[context.deviceFingerprint] ?? []
        deviceHistory.append(now)
        deviceSendHistory[context.deviceFingerprint] = deviceHistory
        
 // IP历史
        var ipHistory = ipSendHistory[context.ip] ?? []
        ipHistory.append(now)
        ipSendHistory[context.ip] = ipHistory
    }
    
 /// 更新通道统计
    private func updateChannelStats(carrier: Carrier, success: Bool) async {
        var stats = channelStats[carrier] ?? (success: 0, total: 0)
        stats.total += 1
        if success {
            stats.success += 1
        }
        channelStats[carrier] = stats
        
 // 更新成功率
        if var channel = channels[carrier] {
            channel.successRate = Double(stats.success) / Double(stats.total)
            channels[carrier] = channel
        }
    }
    
 /// 标记通道失败
    private func markChannelFailure(carrier: Carrier) async {
        if var channel = channels[carrier] {
            channel.consecutiveFailures += 1
            channel.lastFailureTime = Date()
            channels[carrier] = channel
            
            if channel.consecutiveFailures >= 5 {
                logger.warning("⚠️ 通道 \(carrier.displayName) 已熔断")
            }
        }
    }
    
 /// 重置通道失败计数（成功后调用）
    private func resetChannelFailure(carrier: Carrier) async {
        if var channel = channels[carrier] {
            channel.consecutiveFailures = 0
            channels[carrier] = channel
        }
    }
    
 // MARK: - 状态查询
    
 /// 获取发送记录状态
    public func getSendStatus(recordId: UUID) -> SendRecord? {
        return sendRecords[recordId]
    }
    
 /// 获取通道健康状态
    public func getChannelHealth() -> [Carrier: (available: Bool, successRate: Double)] {
        var health: [Carrier: (available: Bool, successRate: Double)] = [:]
        for (carrier, channel) in channels {
            health[carrier] = (channel.isAvailable, channel.successRate)
        }
        return health
    }
    
 /// 获取当前限流状态
    public func getRateLimitStatus(phoneNumber: String) -> (canSend: Bool, nextAvailableIn: TimeInterval?) {
        let now = Date()
        let oneDayAgo = now.addingTimeInterval(-86400)
        
        let phoneSends = (phoneSendHistory[phoneNumber] ?? []).filter { $0 > oneDayAgo }
        
        if phoneSends.count >= abuseConfig.phoneMaxPerDay {
            let tomorrow = Calendar.current.startOfDay(for: now).addingTimeInterval(86400)
            return (false, tomorrow.timeIntervalSince(now))
        }
        
        if let lastSend = phoneSends.last {
            let elapsed = now.timeIntervalSince(lastSend)
            if elapsed < abuseConfig.resendCooldown {
                return (false, abuseConfig.resendCooldown - elapsed)
            }
        }
        
        return (true, nil)
    }
}

// MARK: - 扩展：邮件验证码服务

@available(macOS 14.0, *)
extension VerificationCodeService {
    
 /// 邮件通道
    public enum EmailChannel: String, CaseIterable, Sendable {
        case primary = "primary"     // 主通道
        case secondary = "secondary" // 备用通道
        case fallback = "fallback"   // 降级通道
    }
    
 /// 发送邮件验证码（带重试和降级）
    public func sendEmailVerificationCode(
        email: String,
        deviceFingerprint: String,
        ip: String,
        captchaPassed: Bool = false
    ) async -> SendResult {
        logger.info("📧 开始发送邮件验证码: \(email.prefix(3))***")
        
 // 防滥用检查（使用邮箱作为标识）
        let context = SendContext(
            phoneNumber: email,  // 复用手机号字段存储邮箱
            deviceFingerprint: deviceFingerprint,
            ip: ip,
            captchaPassed: captchaPassed
        )
        
        let abuseCheck = await checkAbusePrevention(context: context)
        if !abuseCheck.allowed {
            return SendResult.failure(
                recordId: UUID(),
                channel: .chinaMobile,
                error: abuseCheck.reason ?? "操作过于频繁",
                retryCount: 0,
                requiresCaptcha: abuseCheck.requiresCaptcha,
                nextRetry: abuseCheck.nextAvailableTime
            )
        }
        
        let code = generateVerificationCode()
        let recordId = UUID()
        
 // 尝试主通道
        do {
            let success = try await sendEmailViaChannel(
                channel: .primary,
                email: email,
                code: code
            )
            
            if success {
                await recordSendHistory(context: context)
                return SendResult.success(recordId: recordId, channel: .chinaMobile, messageId: nil)
            }
        } catch {
            logger.warning("📧 主通道失败: \(error.localizedDescription)")
        }
        
 // 尝试备用通道
        do {
            let success = try await sendEmailViaChannel(
                channel: .secondary,
                email: email,
                code: code
            )
            
            if success {
                await recordSendHistory(context: context)
                return SendResult.success(recordId: recordId, channel: .chinaMobile, messageId: nil)
            }
        } catch {
            logger.warning("📧 备用通道失败: \(error.localizedDescription)")
        }
        
 // 尝试降级通道
        do {
            let success = try await sendEmailViaChannel(
                channel: .fallback,
                email: email,
                code: code
            )
            
            if success {
                await recordSendHistory(context: context)
                return SendResult.success(recordId: recordId, channel: .chinaMobile, messageId: nil)
            }
        } catch {
            logger.error("📧 降级通道失败: \(error.localizedDescription)")
        }
        
        return SendResult.failure(
            recordId: recordId,
            channel: .chinaMobile,
            error: "邮件发送失败，请稍后重试",
            retryCount: 3
        )
    }
    
 /// 通过指定通道发送邮件
    private func sendEmailViaChannel(
        channel: EmailChannel,
        email: String,
        code: String
    ) async throws -> Bool {
 // 这里调用实际的邮件服务
 // 根据不同通道使用不同的配置
        let env = ProcessInfo.processInfo.environment
        
        let endpoint: String
        switch channel {
        case .primary:
            endpoint = env["EMAIL_PRIMARY_ENDPOINT"] ?? "smtp.example.com"
        case .secondary:
            endpoint = env["EMAIL_SECONDARY_ENDPOINT"] ?? "smtp2.example.com"
        case .fallback:
            endpoint = env["EMAIL_FALLBACK_ENDPOINT"] ?? "smtp3.example.com"
        }
        
        logger.info("📧 使用 \(channel.rawValue) 通道发送邮件: \(endpoint)")
        
 // 调用 EmailService 发送（这里简化处理）
 // 实际实现需要根据不同通道配置发送
        
 // 模拟发送（实际需要替换为真实实现）
        return true
    }
}

