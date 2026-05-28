import Foundation
import CryptoKit

/// Public-client OAuth 2.1 + PKCE helper for Nebula.
///
/// This does not replace the current in-app username/password UI yet; it provides
/// the protocol-safe primitives needed to migrate macOS/iOS to system-browser auth.
@MainActor
public final class NebulaPublicClientOAuth: BaseManager {
    public static let shared = NebulaPublicClientOAuth()

    public struct AuthorizationRequest: Sendable, Equatable {
        public let authorizationURL: URL
        public let state: String
        public let codeVerifier: String
        public let codeChallenge: String
        public let redirectURI: String
        public let scopes: [String]
    }

    public struct DiscoveryDocument: Codable, Sendable, Equatable {
        public let issuer: String
        public let authorizationEndpoint: String
        public let tokenEndpoint: String
        public let userinfoEndpoint: String?
        public let revocationEndpoint: String?
        public let codeChallengeMethodsSupported: [String]?

        enum CodingKeys: String, CodingKey {
            case issuer
            case authorizationEndpoint = "authorization_endpoint"
            case tokenEndpoint = "token_endpoint"
            case userinfoEndpoint = "userinfo_endpoint"
            case revocationEndpoint = "revocation_endpoint"
            case codeChallengeMethodsSupported = "code_challenge_methods_supported"
        }
    }

    public struct TokenResponse: Codable, Sendable, Equatable {
        public let accessToken: String
        public let tokenType: String
        public let expiresIn: Int?
        public let refreshToken: String?
        public let scope: String?
        public let idToken: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case scope
            case idToken = "id_token"
        }
    }

    public struct UserInfo: Codable, Sendable, Equatable {
        public let subject: String
        public let preferredUsername: String?
        public let name: String?
        public let email: String?
        public let picture: String?
        public let nebulaId: String?

        enum CodingKeys: String, CodingKey {
            case subject = "sub"
            case preferredUsername = "preferred_username"
            case name
            case email
            case picture
            case nebulaId = "nebula_id"
            case nebulaIdCamel = "nebulaId"
        }

        public init(
            subject: String,
            preferredUsername: String? = nil,
            name: String? = nil,
            email: String? = nil,
            picture: String? = nil,
            nebulaId: String? = nil
        ) {
            self.subject = subject
            self.preferredUsername = preferredUsername
            self.name = name
            self.email = email
            self.picture = picture
            self.nebulaId = NebulaIdentityContract.normalizedNebulaId(nebulaId)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            subject = try container.decode(String.self, forKey: .subject)
            preferredUsername = try container.decodeIfPresent(String.self, forKey: .preferredUsername)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            picture = try container.decodeIfPresent(String.self, forKey: .picture)
            nebulaId = NebulaIdentityContract.normalizedNebulaId(
                try container.decodeIfPresent(String.self, forKey: .nebulaId)
                    ?? container.decodeIfPresent(String.self, forKey: .nebulaIdCamel)
            )
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(subject, forKey: .subject)
            try container.encodeIfPresent(preferredUsername, forKey: .preferredUsername)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(email, forKey: .email)
            try container.encodeIfPresent(picture, forKey: .picture)
            try container.encodeIfPresent(nebulaId, forKey: .nebulaId)
        }
    }

    public enum OAuthError: LocalizedError {
        case configurationMissing
        case invalidBaseURL
        case invalidDiscoveryDocument
        case invalidAuthorizeURL
        case invalidTokenResponse
        case serverError(String)
        case network(Error)

        public var errorDescription: String? {
            switch self {
            case .configurationMissing:
                return "Nebula OAuth 配置缺失，请至少设置 NEBULA_BASE_URL 和 NEBULA_CLIENT_ID"
            case .invalidBaseURL:
                return "Nebula OAuth 基址无效"
            case .invalidDiscoveryDocument:
                return "Nebula OAuth discovery 文档无效"
            case .invalidAuthorizeURL:
                return "Nebula OAuth 授权地址无效"
            case .invalidTokenResponse:
                return "Nebula OAuth token 响应无效"
            case .serverError(let message):
                return message
            case .network(let error):
                return "网络错误：\(error.localizedDescription)"
            }
        }
    }

    private let urlSession: URLSession
    private var cachedDiscovery: DiscoveryDocument?
    private var configurationOverride: NebulaConfigurationResolver.ResolvedConfiguration?

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        self.urlSession = URLSession(configuration: config)
        super.init(category: "NebulaPublicClientOAuth")
    }

    public override func performInitialization() async {
        logger.info("NebulaPublicClientOAuth initialized")
    }

    public func overrideConfiguration(baseURL: String, clientId: String, clientSecret: String? = nil) {
        configurationOverride = NebulaConfigurationResolver.ResolvedConfiguration(
            baseURL: baseURL,
            clientId: clientId,
            clientSecret: clientSecret,
            sourceDescription: "override"
        )
    }

    public func clearConfigurationOverride() {
        configurationOverride = nil
    }

    public func fetchDiscoveryDocument(forceRefresh: Bool = false) async throws -> DiscoveryDocument {
        if let cachedDiscovery, !forceRefresh {
            return cachedDiscovery
        }

        let config = try requireConfiguration()
        guard let wellKnownURL = URL(string: config.baseURL + "/.well-known/openid-configuration") else {
            throw OAuthError.invalidBaseURL
        }

        do {
            let (data, response) = try await urlSession.data(from: wellKnownURL)
            guard let http = response as? HTTPURLResponse else {
                throw OAuthError.invalidDiscoveryDocument
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "discovery_failed"
                throw OAuthError.serverError(message)
            }

            let document = try JSONDecoder().decode(DiscoveryDocument.self, from: data)
            cachedDiscovery = document
            return document
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.network(error)
        }
    }

    public func makeAuthorizationRequest(
        redirectURI: String,
        scopes: [String] = ["openid", "profile", "email", "offline_access"],
        additionalParameters: [String: String] = [:]
    ) throws -> AuthorizationRequest {
        let config = try requireConfiguration()
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let state = Self.generateState()

        guard var components = URLComponents(string: config.baseURL + "/oauth/authorize") else {
            throw OAuthError.invalidAuthorizeURL
        }

        var queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        queryItems.append(contentsOf: additionalParameters.map { URLQueryItem(name: $0.key, value: $0.value) })
        components.queryItems = queryItems

        guard let authorizationURL = components.url else {
            throw OAuthError.invalidAuthorizeURL
        }

        return AuthorizationRequest(
            authorizationURL: authorizationURL,
            state: state,
            codeVerifier: codeVerifier,
            codeChallenge: codeChallenge,
            redirectURI: redirectURI,
            scopes: scopes
        )
    }

    public func makeRegistrationAuthorizationRequest(
        redirectURI: String,
        scopes: [String] = ["openid", "profile", "email", "offline_access"]
    ) throws -> AuthorizationRequest {
        try makeAuthorizationRequest(
            redirectURI: redirectURI,
            scopes: scopes,
            additionalParameters: ["flow": "register"]
        )
    }

    public func exchangeAuthorizationCode(
        _ code: String,
        authorizationRequest: AuthorizationRequest
    ) async throws -> TokenResponse {
        let config = try requireConfiguration()
        guard let tokenURL = URL(string: config.baseURL + "/oauth/token") else {
            throw OAuthError.invalidBaseURL
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncodedData([
            "grant_type": "authorization_code",
            "client_id": config.clientId,
            "code": code,
            "redirect_uri": authorizationRequest.redirectURI,
            "code_verifier": authorizationRequest.codeVerifier
        ])

        do {
            let (data, response) = try await urlSession.data(for: request)
            return try Self.decodeTokenResponse(data: data, response: response)
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.network(error)
        }
    }

    public func refreshToken(_ refreshToken: String) async throws -> TokenResponse {
        let config = try requireConfiguration()
        guard let tokenURL = URL(string: config.baseURL + "/oauth/token") else {
            throw OAuthError.invalidBaseURL
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formURLEncodedData([
            "grant_type": "refresh_token",
            "client_id": config.clientId,
            "refresh_token": refreshToken
        ])

        do {
            let (data, response) = try await urlSession.data(for: request)
            return try Self.decodeTokenResponse(data: data, response: response)
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.network(error)
        }
    }

    public func fetchUserInfo(accessToken: String) async throws -> UserInfo {
        let config = try requireConfiguration()
        guard let userInfoURL = URL(string: config.baseURL + "/oauth/userinfo") else {
            throw OAuthError.invalidBaseURL
        }

        var request = URLRequest(url: userInfoURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OAuthError.invalidTokenResponse
            }
            guard (200..<300).contains(http.statusCode) else {
                let message = String(data: data, encoding: .utf8) ?? "userinfo_failed"
                throw OAuthError.serverError(message)
            }
            return try JSONDecoder().decode(UserInfo.self, from: data)
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.network(error)
        }
    }

    public static func generateCodeVerifier() -> String {
        base64URLEncode(randomBytes(count: 32))
    }

    public static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URLEncode(Data(digest))
    }

    public static func generateState() -> String {
        base64URLEncode(randomBytes(count: 24))
    }

    private func requireConfiguration() throws -> NebulaConfigurationResolver.ResolvedConfiguration {
        if let configurationOverride {
            return configurationOverride
        }
        guard let resolved = NebulaConfigurationResolver.resolve() else {
            throw OAuthError.configurationMissing
        }
        return resolved
    }

    private static func decodeTokenResponse(data: Data, response: URLResponse) throws -> TokenResponse {
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidTokenResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "token_exchange_failed"
            throw OAuthError.serverError(message)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func randomBytes(count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    private static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formURLEncodedData(_ fields: [String: String]) -> Data {
        let encoded = fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                "\(percentEncode(key))=\(percentEncode(value))"
            }
            .joined(separator: "&")
        return Data(encoded.utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=%\" ")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
