import Foundation
import CryptoKit
import os.log

/// 旧客户端短信直连服务。
/// 1.0 手机验证码已收敛到 Supabase Phone OTP + send_sms hook + 阿里云，本类型仅用于识别并清理遗留本机凭证。
@MainActor
public final class SMSService: BaseManager {
    
 // MARK: - 配置
    
 /// 阿里云短信服务配置
    public struct Configuration: Sendable {
        public let accessKeyId: String
        public let accessKeySecret: String
        public let signName: String
        public let templateCode: String
        public let endpoint: String
        
        public init(accessKeyId: String,
                   accessKeySecret: String,
                   signName: String,
                   templateCode: String,
                   endpoint: String = "dysmsapi.aliyuncs.com") {
            self.accessKeyId = accessKeyId
            self.accessKeySecret = accessKeySecret
            self.signName = signName
            self.templateCode = templateCode
            self.endpoint = endpoint
        }
    }
    
 // MARK: - 错误类型
    
    public enum SMSError: LocalizedError {
        case configurationMissing
        case invalidPhoneNumber
        case networkError(Error)
        case apiError(String)
        case signatureError
        case rateLimitExceeded
        case serverManagedOnly
        
        public var errorDescription: String? {
            switch self {
            case .configurationMissing:
                return "短信服务配置缺失，请检查AccessKey和模板配置"
            case .invalidPhoneNumber:
                return "手机号码格式不正确"
            case .networkError(let error):
                return "网络请求失败：\(error.localizedDescription)"
            case .apiError(let message):
                return "短信API错误：\(message)"
            case .signatureError:
                return "签名生成失败"
            case .rateLimitExceeded:
                return "发送频率过快，请稍后再试"
            case .serverManagedOnly:
                return "短信验证码已改为服务端发送，客户端短信直连能力在 1.0 中停用"
            }
        }
    }
    
 // MARK: - 属性
    
    public static let shared = SMSService()
    
    private let urlSession: URLSession
    private var configuration: Configuration?
    
 // 发送频率限制
    private var lastSendTime: [String: Date] = [:]
    private let sendInterval: TimeInterval = 60 // 60秒间隔
    
 // MARK: - 初始化

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        urlSession = URLSession(configuration: config)
        
        super.init(category: "SMSService")
        
 // 从环境变量加载配置
        loadConfigurationFromEnvironment()
    }
    
 // MARK: - 生命周期管理
    
    override public func performInitialization() async {
        logger.info("SMSService 初始化完成，当前仅保留遗留短信凭证清理能力")
    }
    
 // MARK: - 配置管理
    
 /// 更新短信服务配置
    public func updateConfiguration(_ configuration: Configuration) {
        self.configuration = nil
        logger.warning("忽略客户端短信配置更新请求；生产短信链路已迁移到服务端 Supabase send_sms hook")
    }
    
 /// 检查是否存在遗留客户端短信凭证
    private func loadConfigurationFromEnvironment() {
        configuration = nil
        if KeychainManager.shared.hasLegacySMSConfig() {
            logger.warning("检测到旧版客户端短信凭证；这些凭证不会再被用于生产发码，请尽快清理")
        } else {
            logger.info("未检测到客户端短信凭证，短信链路已完全交由服务端托管")
        }
    }
    
 // MARK: - 短信发送
    
 /// 发送验证码短信
 /// - Parameters:
 /// - phoneNumber: 手机号码
 /// - code: 验证码
 /// - Returns: 发送结果
    public func sendVerificationCode(to phoneNumber: String, code: String) async throws -> SMSResult {
        logger.warning("拒绝客户端短信直连请求: \(phoneNumber.prefix(3))****\(phoneNumber.suffix(4))")
        _ = code
        throw SMSError.serverManagedOnly
    }
    
 // MARK: - 私有方法
    
 /// 验证手机号格式
    private func isValidPhoneNumber(_ phoneNumber: String) -> Bool {
 // 支持中国大陆手机号格式：1[3-9]\d{9}
        let phoneRegex = "^1[3-9]\\d{9}$"
        let phonePredicate = NSPredicate(format: "SELF MATCHES %@", phoneRegex)
        return phonePredicate.evaluate(with: phoneNumber)
    }
    
 /// 检查发送频率限制
    private func checkRateLimit(for phoneNumber: String) throws {
        if let lastTime = lastSendTime[phoneNumber] {
            let timeSinceLastSend = Date().timeIntervalSince(lastTime)
            if timeSinceLastSend < sendInterval {
                throw SMSError.rateLimitExceeded
            }
        }
    }
    
 /// 构建短信请求参数
    private func buildSMSParameters(
        config: Configuration,
        phoneNumber: String,
        templateParam: [String: String]
    ) -> [String: String] {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let nonce = UUID().uuidString
        
        let templateParamJSON = try? JSONSerialization.data(withJSONObject: templateParam)
        let templateParamString = templateParamJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        
        return [
            "AccessKeyId": config.accessKeyId,
            "Action": "SendSms",
            "Format": "JSON",
            "PhoneNumbers": phoneNumber,
            "SignName": config.signName,
            "TemplateCode": config.templateCode,
            "TemplateParam": templateParamString,
            "Timestamp": timestamp,
            "SignatureMethod": "HMAC-SHA1",
            "SignatureNonce": nonce,
            "SignatureVersion": "1.0",
            "Version": "2017-05-25"
        ]
    }
    
 /// 生成阿里云API签名
    private func generateSignature(parameters: [String: String], secret: String) throws -> String {
 // 1. 对参数进行排序
        let sortedParams = parameters.sorted { $0.key < $1.key }
        
 // 2. 构建查询字符串
        let queryString = sortedParams
            .map { "\(percentEncode($0.key))=\(percentEncode($0.value))" }
            .joined(separator: "&")
        
 // 3. 构建待签名字符串
        let stringToSign = "GET&\(percentEncode("/"))&\(percentEncode(queryString))"
        
 // 4. 计算HMAC-SHA1签名
        let key = "\(secret)&"
        guard let keyData = key.data(using: .utf8),
              let stringData = stringToSign.data(using: .utf8) else {
            throw SMSError.signatureError
        }
        
        let signature = HMAC<Insecure.SHA1>.authenticationCode(for: stringData, using: SymmetricKey(data: keyData))
        return Data(signature).base64EncodedString()
    }
    
 /// URL编码
    private func percentEncode(_ string: String) -> String {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~")
        return string.addingPercentEncoding(withAllowedCharacters: unreserved) ?? string
    }
    
 /// 发送短信请求
    private func sendSMSRequest(
        parameters: [String: String],
        signature: String,
        endpoint: String
    ) async throws -> SMSResult {
 // 构建完整参数（包含签名）
        var fullParameters = parameters
        fullParameters["Signature"] = signature
        
 // 构建URL
        let queryString = fullParameters
            .map { "\($0.key)=\(percentEncode($0.value))" }
            .joined(separator: "&")
        
        guard let url = URL(string: "https://\(endpoint)?\(queryString)") else {
            throw SMSError.networkError(URLError(.badURL))
        }
        
 // 创建请求
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
 // 发送请求
        do {
            let (data, response) = try await urlSession.data(for: request)
            
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SMSError.networkError(URLError(.badServerResponse))
            }
            
 // 解析响应
            return try parseSMSResponse(data: data, statusCode: httpResponse.statusCode)
            
        } catch {
            throw SMSError.networkError(error)
        }
    }
    
 /// 解析短信API响应
    private func parseSMSResponse(data: Data, statusCode: Int) throws -> SMSResult {
        guard statusCode == 200 else {
            throw SMSError.apiError("HTTP \(statusCode)")
        }
        
        do {
            let response = try JSONDecoder().decode(AliyunSMSResponse.self, from: data)
            
            if response.code == "OK" {
                return SMSResult(
                    success: true,
                    messageId: response.bizId,
                    message: response.message
                )
            } else {
                throw SMSError.apiError(response.message ?? "Unknown error")
            }
            
        } catch let decodingError as DecodingError {
            logger.error("Failed to decode SMS response: \(decodingError)")
            throw SMSError.apiError("响应解析失败")
        }
    }
    
 // MARK: - 注册成功通知
    
 /// 发送注册成功短信
 /// - Parameters:
 /// - phoneNumber: 手机号码
 /// - username: 用户名
 /// - nebulaId: Nebula ID
 /// - Returns: 发送结果
    public func sendRegistrationSuccessSMS(to phoneNumber: String, username: String, nebulaId: String) async throws -> SMSResult {
 // 验证配置
        guard let config = configuration else {
            throw SMSError.configurationMissing
        }
        
 // 验证手机号格式
        guard isValidPhoneNumber(phoneNumber) else {
            throw SMSError.invalidPhoneNumber
        }
        
        logger.info("📱 发送注册成功短信到: \(phoneNumber.prefix(3))****\(phoneNumber.suffix(4))")
        
        do {
 // 构建短信模板参数
 // 注意：这里需要配置专门的注册成功模板
            let templateParam: [String: String] = [
                "username": username,
                "nebula_id": String(nebulaId.suffix(8))  // 只显示后8位，保护隐私
            ]
            
 // 构建请求参数（使用注册成功模板）
            let registrationTemplateCode = ProcessInfo.processInfo.environment["ALIYUN_SMS_REGISTRATION_TEMPLATE"] ?? "SMS_REGISTRATION_SUCCESS"
            
            let parameters = buildRegistrationSMSParameters(
                config: config,
                phoneNumber: phoneNumber,
                templateCode: registrationTemplateCode,
                templateParam: templateParam
            )
            
 // 生成签名
            let signature = try generateSignature(parameters: parameters, secret: config.accessKeySecret)
            
 // 发送请求
            let result = try await sendSMSRequest(
                parameters: parameters,
                signature: signature,
                endpoint: config.endpoint
            )
            
            if result.success {
                logger.info("✅ 注册成功短信已发送: \(phoneNumber.prefix(3))****\(phoneNumber.suffix(4))")
            } else {
                logger.warning("⚠️ 注册成功短信发送失败: \(result.message ?? "未知原因")")
            }
            
            return result
            
        } catch {
            logger.error("❌ 发送注册成功短信失败: \(error.localizedDescription)")
            throw error
        }
    }
    
 /// 构建注册成功短信请求参数
    private func buildRegistrationSMSParameters(
        config: Configuration,
        phoneNumber: String,
        templateCode: String,
        templateParam: [String: String]
    ) -> [String: String] {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let nonce = UUID().uuidString
        
        let templateParamJSON = try? JSONSerialization.data(withJSONObject: templateParam)
        let templateParamString = templateParamJSON.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        
        return [
            "AccessKeyId": config.accessKeyId,
            "Action": "SendSms",
            "Format": "JSON",
            "PhoneNumbers": phoneNumber,
            "SignName": config.signName,
            "TemplateCode": templateCode,
            "TemplateParam": templateParamString,
            "Timestamp": timestamp,
            "SignatureMethod": "HMAC-SHA1",
            "SignatureNonce": nonce,
            "SignatureVersion": "1.0",
            "Version": "2017-05-25"
        ]
    }
    
 /// 生成注册成功短信内容模板
 /// 注意：实际使用时需要在阿里云短信控制台配置对应的模板
    public func getRegistrationSuccessSMSTemplate() -> String {
        return """
        【SkyBridge】亲爱的${username}，恭喜您成功注册SkyBridge账户！您的Nebula ID后8位为：${nebula_id}。请妥善保管账户信息，如非本人操作请忽略。
        """
    }
}

// MARK: - 数据模型

/// 短信发送结果
public struct SMSResult: Sendable {
    public let success: Bool
    public let messageId: String?
    public let message: String?
    
    public init(success: Bool, messageId: String? = nil, message: String? = nil) {
        self.success = success
        self.messageId = messageId
        self.message = message
    }
}

/// 阿里云短信API响应
private struct AliyunSMSResponse: Codable {
    let code: String
    let message: String?
    let bizId: String?
    let requestId: String?
    
    enum CodingKeys: String, CodingKey {
        case code = "Code"
        case message = "Message"
        case bizId = "BizId"
        case requestId = "RequestId"
    }
}
