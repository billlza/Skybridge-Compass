import Foundation
import CryptoKit
import AuthenticationServices
#if canImport(UIKit)
import UIKit
#endif

@available(iOS 17.0, *)
@MainActor
public final class NebulaPublicClientOAuth {
    public static let shared = NebulaPublicClientOAuth()

    public struct AuthorizationRequest: Sendable, Equatable {
        public let authorizationURL: URL
        public let state: String
        public let codeVerifier: String
        public let codeChallenge: String
        public let redirectURI: String
        public let scopes: [String]
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
            self.nebulaId = Self.normalizedNebulaId(nebulaId)
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            subject = try container.decode(String.self, forKey: .subject)
            preferredUsername = try container.decodeIfPresent(String.self, forKey: .preferredUsername)
            name = try container.decodeIfPresent(String.self, forKey: .name)
            email = try container.decodeIfPresent(String.self, forKey: .email)
            picture = try container.decodeIfPresent(String.self, forKey: .picture)
            nebulaId = Self.normalizedNebulaId(
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

        private static func normalizedNebulaId(_ raw: String?) -> String? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return nil
            }
            return trimmed
        }
    }

    public enum OAuthError: LocalizedError {
        case configurationMissing
        case invalidAuthorizeURL
        case invalidCallback
        case serverError(String)
        case network(Error)

        public var errorDescription: String? {
            switch self {
            case .configurationMissing:
                return "Nebula OAuth 配置缺失，请至少设置 NEBULA_BASE_URL 和 NEBULA_CLIENT_ID"
            case .invalidAuthorizeURL:
                return "Nebula 授权地址无效"
            case .invalidCallback:
                return "Nebula 回调无效"
            case .serverError(let message):
                return message
            case .network(let error):
                return "网络错误：\(error.localizedDescription)"
            }
        }
    }

    private let urlSession: URLSession

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        self.urlSession = URLSession(configuration: config)
    }

    public func makeAuthorizationRequest(
        redirectURI: String,
        scopes: [String] = ["openid", "profile", "email", "offline_access"]
    ) throws -> AuthorizationRequest {
        let config = try requireConfiguration()
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let state = Self.generateState()

        guard var components = URLComponents(string: config.baseURL + "/oauth/authorize") else {
            throw OAuthError.invalidAuthorizeURL
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]

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
        let config = try requireConfiguration()
        let codeVerifier = Self.generateCodeVerifier()
        let codeChallenge = Self.codeChallenge(for: codeVerifier)
        let state = Self.generateState()

        guard var components = URLComponents(string: config.baseURL + "/oauth/authorize") else {
            throw OAuthError.invalidAuthorizeURL
        }
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: config.clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "flow", value: "register")
        ]

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

    public func exchangeAuthorizationCode(
        _ code: String,
        authorizationRequest: AuthorizationRequest
    ) async throws -> TokenResponse {
        let config = try requireConfiguration()
        guard let tokenURL = URL(string: config.baseURL + "/oauth/token") else {
            throw OAuthError.invalidAuthorizeURL
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

    public func fetchUserInfo(accessToken: String) async throws -> UserInfo {
        let config = try requireConfiguration()
        guard let userInfoURL = URL(string: config.baseURL + "/oauth/userinfo") else {
            throw OAuthError.invalidAuthorizeURL
        }

        var request = URLRequest(url: userInfoURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw OAuthError.invalidCallback
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

    public func revokeTokens(accessToken: String, refreshToken: String?) async throws {
        let config = try requireConfiguration()
        let tokens = [refreshToken, accessToken]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for token in tokens {
            guard let revokeURL = URL(string: config.baseURL + "/oauth/revoke") else {
                throw OAuthError.invalidAuthorizeURL
            }

            var request = URLRequest(url: revokeURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "token": token,
                "client_id": config.clientId
            ])

            do {
                let (data, response) = try await urlSession.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw OAuthError.invalidCallback
                }
                guard (200..<300).contains(http.statusCode) else {
                    let message = String(data: data, encoding: .utf8) ?? "revoke_failed"
                    throw OAuthError.serverError(message)
                }
            } catch let error as OAuthError {
                throw error
            } catch {
                throw OAuthError.network(error)
            }
        }
    }

    public func authenticateUsingSystemBrowser() async throws -> (TokenResponse, UserInfo) {
        let authorizationRequest = try makeAuthorizationRequest(redirectURI: "skybridge://auth/nebula")
        return try await completeAuthorization(authorizationRequest)
    }

    public func registerUsingSystemBrowser() async throws -> (TokenResponse, UserInfo) {
        let authorizationRequest = try makeRegistrationAuthorizationRequest(redirectURI: "skybridge://auth/nebula")
        return try await completeAuthorization(authorizationRequest)
    }

    private func completeAuthorization(_ authorizationRequest: AuthorizationRequest) async throws -> (TokenResponse, UserInfo) {
        let callbackURL = try await NebulaBrowserAuthenticationCoordinator.shared.start(
            url: authorizationRequest.authorizationURL,
            callbackScheme: "skybridge"
        )

        guard let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidCallback
        }
        let queryItems = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        if let error = queryItems["error"], !error.isEmpty {
            let description = queryItems["error_description"].flatMap { $0.isEmpty ? nil : $0 } ?? error
            throw OAuthError.serverError(description)
        }

        guard queryItems["state"] == authorizationRequest.state else {
            throw OAuthError.invalidCallback
        }
        guard let code = queryItems["code"], !code.isEmpty else {
            throw OAuthError.invalidCallback
        }

        let tokenResponse = try await exchangeAuthorizationCode(code, authorizationRequest: authorizationRequest)
        let userInfo = try await fetchUserInfo(accessToken: tokenResponse.accessToken)
        return (tokenResponse, userInfo)
    }

    private func requireConfiguration() throws -> (baseURL: String, clientId: String) {
        guard let baseURL = SkyBridgeServerConfig.nebulaBaseURL,
              let clientId = SkyBridgeServerConfig.nebulaClientID,
              !baseURL.isEmpty,
              !clientId.isEmpty else {
            throw OAuthError.configurationMissing
        }
        return (baseURL, clientId)
    }

    private static func decodeTokenResponse(data: Data, response: URLResponse) throws -> TokenResponse {
        guard let http = response as? HTTPURLResponse else {
            throw OAuthError.invalidCallback
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? "token_exchange_failed"
            throw OAuthError.serverError(message)
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private static func generateCodeVerifier() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func generateState() -> String {
        Data((0..<24).map { _ in UInt8.random(in: .min ... .max) })
            .base64EncodedString()
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

@available(iOS 17.0, *)
@MainActor
final class NebulaBrowserAuthenticationCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = NebulaBrowserAuthenticationCoordinator()

    private var session: ASWebAuthenticationSession?

    func start(url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                Task { @MainActor in
                    self.session = nil
                }

                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: NebulaPublicClientOAuth.OAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            if !session.start() {
                self.session = nil
                continuation.resume(throwing: NebulaPublicClientOAuth.OAuthError.invalidAuthorizeURL)
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
#if canImport(UIKit)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let window = windowScene.windows.first(where: \.isKeyWindow) {
            return window
        }
#endif
        return ASPresentationAnchor()
    }
}
