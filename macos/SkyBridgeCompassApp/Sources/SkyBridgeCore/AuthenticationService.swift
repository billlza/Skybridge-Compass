import Foundation
import Combine
import Security

/// 负责处理所有 SkyBridge 账户登录、注册与会话持久化逻辑的核心服务。
public final class AuthenticationService {
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

    private let sessionSubject = CurrentValueSubject<AuthSession?, Never>(nil)
    private let urlSession: URLSession
    private let keychainService = "com.skybridge.compass.authsession"
    private let keychainAccount = "primary"
    private let queue = DispatchQueue(label: "com.skybridge.compass.auth", attributes: .concurrent)

    private var configuration: Configuration?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        urlSession = URLSession(configuration: config)
        configuration = Self.loadConfigurationFromEnvironment()
        if let session = try? loadSessionFromKeychain() {
            sessionSubject.send(session)
        }
    }

    /// 使用真实的配置覆盖默认设置，通常在应用启动阶段调用。
    public func updateConfiguration(_ configuration: Configuration) {
        queue.async(flags: .barrier) {
            self.configuration = configuration
        }
    }

    /// 将 Sign in with Apple 返回的身份凭据交给后端换取 SkyBridge 会话。
    public func authenticateWithApple(identityToken: Data,
                                       authorizationCode: Data?) async throws -> AuthSession {
        let payload = ApplePayload(identityToken: identityToken.base64EncodedString(),
                                   authorizationCode: authorizationCode?.base64EncodedString())
        return try await performRequest(endpoint: configuration?.appleEndpoint, payload: payload)
    }

    /// 通过星云账号体系登录。
    public func loginNebula(account: String, password: String) async throws -> AuthSession {
        let payload = NebulaPayload(account: account, password: password)
        return try await performRequest(endpoint: configuration?.nebulaEndpoint, payload: payload)
    }

    /// 使用手机号和短信验证码登录。
    public func loginPhone(number: String, code: String) async throws -> AuthSession {
        let payload = PhonePayload(number: number, code: code)
        return try await performRequest(endpoint: configuration?.phoneEndpoint, payload: payload)
    }

    /// 使用邮箱与密码登录。
    public func loginEmail(email: String, password: String) async throws -> AuthSession {
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
        queue.async(flags: .barrier) {
            self.sessionSubject.send(nil)
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: self.keychainService,
                kSecAttrAccount as String: self.keychainAccount
            ]
            SecItemDelete(query as CFDictionary)
        }
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
        if let base = ProcessInfo.processInfo.environment["SKYBRIDGE_AUTH_BASEURL"],
           let url = URL(string: base) {
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

private struct RegisterPayload: Encodable {
    let displayName: String
    let email: String
    let phone: String
    let password: String
}
