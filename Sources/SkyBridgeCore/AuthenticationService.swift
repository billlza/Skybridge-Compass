import Foundation
import Combine
import Security

/// 负责处理所有 SkyBridge 账户登录、注册与会话持久化逻辑的核心服务。
@MainActor public final class AuthenticationService: BaseManager {
 /// 登录配置，必须使用真实环境的接口地址。
    public struct Configuration: Sendable {
        public let appleEndpoint: URL
        public let nebulaEndpoint: URL
        public let phoneEndpoint: URL
        public let emailEndpoint: URL
        public let registerEndpoint: URL

        public init(baseURL: URL) {
            self.appleEndpoint = baseURL.appending(path: "/auth/apple/exchange")
            self.nebulaEndpoint = baseURL.appending(path: "/auth/nebula/login")
            self.phoneEndpoint = baseURL.appending(path: "/auth/phone/login")
            self.emailEndpoint = baseURL.appending(path: "/auth/email/login")
            self.registerEndpoint = baseURL.appending(path: "/auth/register")
        }

        public init(appleEndpoint: URL,
                    nebulaEndpoint: URL,
                    phoneEndpoint: URL,
                    emailEndpoint: URL,
                    registerEndpoint: URL) {
            self.appleEndpoint = appleEndpoint
            self.nebulaEndpoint = nebulaEndpoint
            self.phoneEndpoint = phoneEndpoint
            self.emailEndpoint = emailEndpoint
            self.registerEndpoint = registerEndpoint
        }
    }
    
 /// 与身份鉴权相关的统一错误类型。
    public enum AuthenticationError: LocalizedError {
        case configurationMissing
        case invalidResponse
        case server(String)
        case storage(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .configurationMissing:
                return "未配置真实登录接口，请先设置 SKYBRIDGE_AUTH_BASEURL 或在应用启动时提供配置"
            case .invalidResponse:
                return "服务器返回的数据格式无效"
            case .server(let message):
                return message
            case .storage(let status):
                return "钥匙串存储失败，状态码 \(status)"
            }
        }
    }

    public static let shared = AuthenticationService()

 /// 对外暴露的当前会话发布者，方便界面实时更新。
    public var sessionPublisher: AnyPublisher<AuthSession?, Never> {
        sessionSubject.eraseToAnyPublisher()
    }

 /// 获取当前会话的访问令牌（若存在）
    public func currentAccessToken() -> String? {
        sessionSubject.value?.accessToken
    }

    private let sessionSubject = CurrentValueSubject<AuthSession?, Never>(nil)
    private let urlSession: URLSession
    private let keychainService = "com.skybridge.compass.authsession"
    private let keychainAccount = "primary"

    private var configuration: Configuration?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config)
        
        super.init(category: "AuthenticationService")
        
        configuration = Self.loadConfigurationFromEnvironment()
        if let session = try? loadSessionFromKeychain() {
            sessionSubject.send(session)
        }
    }
    
 // MARK: - 生命周期管理
    
    override public func performInitialization() async {
        logger.info("AuthenticationService 初始化完成")
    }

 /// 启用Supabase认证模式
    public func enableSupabaseMode(supabaseConfig: SupabaseService.Configuration) {
 // 更新Supabase配置
        SupabaseService.shared.updateConfiguration(supabaseConfig)
        
 // 设置一个标记表示使用Supabase模式
        self.configuration = Configuration(baseURL: URL(string: "supabase://enabled")!)
    }
    
 /// 使用真实的配置覆盖默认设置，通常在应用启动阶段调用。
    public func updateConfiguration(_ configuration: Configuration) {
 // @MainActor 类中直接赋值，避免跨 actor 的并发闭包警告
        self.configuration = configuration
    }

 /// 将 Sign in with Apple 返回的身份凭据交给后端换取 SkyBridge 会话。
    public func authenticateWithApple(identityToken: Data,
                                       authorizationCode: Data?) async throws -> AuthSession {
 // 检查是否使用Supabase模式
        if configuration?.appleEndpoint.scheme == "supabase" {
            let session = try await SupabaseService.shared.signInWithApple(
                identityToken: identityToken.base64EncodedString(),
                nonce: nil
            )
            try store(session: session)
            sessionSubject.send(session)
            return session
        }
        
        let payload = ApplePayload(identityToken: identityToken.base64EncodedString(),
                                   authorizationCode: authorizationCode?.base64EncodedString())
        return try await performRequest(endpoint: configuration?.appleEndpoint, payload: payload)
    }

 /// 星云登录
 /// - Parameters:
 /// - username: 用户名
 /// - password: 密码
 /// - Returns: 认证结果
    public func authenticateWithNebula(username: String, password: String) async throws -> AuthSession {
        let payload = NebulaPayload(account: username, password: password)
        return try await performRequest(endpoint: configuration?.nebulaEndpoint, payload: payload)
    }
    
 /// 验证星云MFA
 /// - Parameters:
 /// - mfaToken: MFA令牌
 /// - code: 验证码
 /// - Returns: 认证结果
    public func verifyNebulaMFA(mfaToken: String, code: String) async throws -> AuthSession {
        let payload = NebulaMFAPayload(mfaToken: mfaToken, code: code)
        return try await performRequest(endpoint: configuration?.nebulaEndpoint, payload: payload)
    }

 /// 发送手机验证码
    public func sendPhoneVerificationCode(to phoneNumber: String) async throws -> String {
 // 检查是否使用Supabase模式
        if configuration?.phoneEndpoint.scheme == "supabase" {
            try await SupabaseService.shared.sendPhoneOTP(phone: phoneNumber)
            return "验证码已通过Supabase发送"
        }
        
        guard let endpoint = configuration?.phoneEndpoint else {
            throw AuthenticationError.configurationMissing
        }
        
        var request = URLRequest(url: endpoint.appendingPathComponent("send-code"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let payload = ["phoneNumber": phoneNumber]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        
        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw AuthenticationError.server("发送验证码失败")
        }
        
        if let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = result["message"] as? String {
            return message
        }
        return "验证码已发送"
    }

 /// 使用手机号和短信验证码登录。
    public func loginPhone(number: String, code: String) async throws -> AuthSession {
 // 检查是否使用Supabase模式
        if configuration?.phoneEndpoint.scheme == "supabase" {
            let session = try await SupabaseService.shared.signInWithPhone(phone: number, token: code)
            try store(session: session)
            sessionSubject.send(session)
            return session
        }
        
        let payload = PhonePayload(number: number, code: code)
        return try await performRequest(endpoint: configuration?.phoneEndpoint, payload: payload)
    }

 /// 邮箱登录
 /// - Parameters:
 /// - email: 邮箱地址
 /// - password: 密码
 /// - Returns: 认证会话
    public func loginEmail(email: String, password: String) async throws -> AuthSession {
 // 检查是否使用Supabase模式
        if configuration?.emailEndpoint.scheme == "supabase" {
            let session = try await SupabaseService.shared.signInWithEmail(email: email, password: password)
 // 确保会话被正确存储和发布
            try store(session: session)
            sessionSubject.send(session)
            return session
        }
        
        let payload = EmailPayload(email: email, password: password)
        return try await performRequest(endpoint: configuration?.emailEndpoint, payload: payload)
    }

 /// 注册全新的 SkyBridge 账户。
    public func register(displayName: String,
                         email: String,
                         phone: String,
                         password: String) async throws -> AuthSession {
        let payload = RegisterPayload(displayName: displayName,
                                      email: email,
                                      phone: phone,
                                      password: password)
        return try await performRequest(endpoint: configuration?.registerEndpoint, payload: payload)
    }

 /// 主动注销并清除钥匙串中的会话信息。
    public func signOut() {
 // 在主 actor 上清理状态并删除钥匙串项
        self.sessionSubject.send(nil)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.keychainService,
            kSecAttrAccount as String: self.keychainAccount
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// 持久化并广播新的会话（例如刷新访问令牌后）。
    public func updateSession(_ session: AuthSession) throws {
        try store(session: session)
        sessionSubject.send(session)
    }

    private func performRequest<P: Encodable>(endpoint: URL?, payload: P) async throws -> AuthSession {
        guard let endpoint else {
            throw AuthenticationError.configurationMissing
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthenticationError.invalidResponse
        }

        if !(200..<300).contains(httpResponse.statusCode) {
            if let message = try? JSONDecoder().decode(ServerMessage.self, from: data) {
                throw AuthenticationError.server(message.message)
            }
            throw AuthenticationError.server("服务器返回状态码 \(httpResponse.statusCode)")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let authResponse = try decoder.decode(AuthResponse.self, from: data)
        let session = authResponse.session
        try store(session: session)
        sessionSubject.send(session)
        return session
    }

    private func store(session: AuthSession) throws {
        let data = try JSONEncoder().encode(session)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]
        let status: OSStatus
        if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        } else {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            status = SecItemAdd(addQuery as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw AuthenticationError.storage(status)
        }
    }

    private func loadSessionFromKeychain() throws -> AuthSession? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return nil
        }
        guard let data = item as? Data else {
            return nil
        }
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    private static func loadConfigurationFromEnvironment() -> Configuration? {
 // 1. 优先尝试从环境变量读取
        if let base = ProcessInfo.processInfo.environment["SKYBRIDGE_AUTH_BASEURL"],
           let url = URL(string: base) {
            return Configuration(baseURL: url)
        }
        
 // 2. 尝试从 Info.plist 读取 (便于打包配置)
        if let base = Bundle.main.object(forInfoDictionaryKey: "SKYBRIDGE_AUTH_BASEURL") as? String,
           let url = URL(string: base) {
            return Configuration(baseURL: url)
        }
        
 // 3. 默认 Fallback 配置 - 解决重启后环境变量丢失导致无法登录的问题
 // 注意：生产环境应确保使用正确的 API 地址
        #if DEBUG
        let defaultBase = "http://localhost:8080"
        #else
        let defaultBase = "https://api.skybridge.com"
        #endif
        
        if let url = URL(string: defaultBase) {
            return Configuration(baseURL: url)
        }
        
        return nil
    }
}

private struct AuthResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let userIdentifier: String
    let displayName: String
    let issuedAt: Date

    var session: AuthSession {
        AuthSession(accessToken: accessToken,
                    refreshToken: refreshToken,
                    userIdentifier: userIdentifier,
                    displayName: displayName,
                    issuedAt: issuedAt)
    }
}

private struct ServerMessage: Decodable {
    let message: String
}

private struct ApplePayload: Encodable {
    let identityToken: String
    let authorizationCode: String?
}

private struct NebulaPayload: Encodable {
    let account: String
    let password: String
}

private struct PhonePayload: Encodable {
    let number: String
    let code: String
}

private struct EmailPayload: Encodable {
    let email: String
    let password: String
}

private struct NebulaMFAPayload: Encodable {
    let mfaToken: String
    let code: String
}

private struct RegisterPayload: Encodable {
    let displayName: String
    let email: String
    let phone: String
    let password: String
}
