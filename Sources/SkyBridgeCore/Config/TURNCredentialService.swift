import Foundation
import OSLog
import SkyBridgeProtocolCore

public actor TURNCredentialService {
    public static let shared = TURNCredentialService(
        credentialEndpointProvider: {
            URL(string: "\(SkyBridgeServerConfig.signalingServerURL)/api/turn/credentials")
        },
        urlSession: .shared,
        deviceIDProvider: {
            await DeviceIdentityKeyManager.shared.getDeviceId()
        },
        allowStaticTURNFallbackProvider: {
            SkyBridgeServerConfig.allowStaticTURNFallback
        },
        fallbackTURNURLsProvider: {
            SkyBridgeServerConfig.turnURLs
        },
        requiresDeviceID: false,
        requestTimeout: 10
    )

    private struct CachedTurnEntry: Sendable {
        let credentials: TURNCredentials
        let turnAdmissionToken: String
    }

    private var cachedCredentialsBySessionID: [String: CachedTurnEntry] = [:]
    private let expirationBuffer: TimeInterval = 30
    private let logger = Logger(subsystem: "com.skybridge.turn", category: "CredentialService")
    private let credentialEndpointProvider: @Sendable () -> URL?
    private let urlSession: URLSession
    private let deviceIDProvider: @Sendable () async -> String
    private let allowStaticTURNFallbackProvider: @Sendable () -> Bool
    private let fallbackTURNURLsProvider: @Sendable () -> [String]
    private let requiresDeviceID: Bool
    private let requestTimeout: TimeInterval

    private init(
        credentialEndpointProvider: @escaping @Sendable () -> URL?,
        urlSession: URLSession,
        deviceIDProvider: @escaping @Sendable () async -> String,
        allowStaticTURNFallbackProvider: @escaping @Sendable () -> Bool,
        fallbackTURNURLsProvider: @escaping @Sendable () -> [String],
        requiresDeviceID: Bool,
        requestTimeout: TimeInterval
    ) {
        self.credentialEndpointProvider = credentialEndpointProvider
        self.urlSession = urlSession
        self.deviceIDProvider = deviceIDProvider
        self.allowStaticTURNFallbackProvider = allowStaticTURNFallbackProvider
        self.fallbackTURNURLsProvider = fallbackTURNURLsProvider
        self.requiresDeviceID = requiresDeviceID
        self.requestTimeout = requestTimeout
    }

    /// Creates a run-owned credential service for the formal interoperability path.
    /// It never consults the product identity singleton or static TURN credentials.
    static func formal(
        credentialEndpoint: URL?,
        urlSession: URLSession,
        deviceID: String,
        requestTimeout: TimeInterval = 10
    ) -> TURNCredentialService {
        TURNCredentialService(
            credentialEndpointProvider: { credentialEndpoint },
            urlSession: urlSession,
            deviceIDProvider: { deviceID },
            allowStaticTURNFallbackProvider: { false },
            fallbackTURNURLsProvider: { [] },
            requiresDeviceID: true,
            requestTimeout: requestTimeout
        )
    }

    public struct TURNCredentials: Sendable, Codable {
        public let username: String
        public let password: String
        public let ttl: Int
        public let uris: [String]
        public let expiresAt: Date

        public init(username: String, password: String, ttl: Int, uris: [String], expiresAt: Date) {
            self.username = username
            self.password = password
            self.ttl = ttl
            self.uris = uris
            self.expiresAt = expiresAt
        }

        public func isValid(buffer: TimeInterval = 30) -> Bool {
            Date().addingTimeInterval(buffer) < expiresAt
        }
    }

    private struct ServerResponse: Codable {
        let username: String
        let password: String
        let ttl: Int
        let uris: [String]?
        let expiresAt: Int?
        let mode: String?
    }

    public enum TURNCredentialError: Error, LocalizedError {
        case endpointNotConfigured
        case missingTurnAdmissionToken
        case missingDeviceID
        case networkError(Error)
        case invalidResponse(String)
        case serverError(Int, String?)
        case decodingFailed(Error)
        case refreshRequiresNewTurnAdmissionToken

        public var errorDescription: String? {
            switch self {
            case .endpointNotConfigured:
                return "TURN 凭据端点未配置"
            case .missingTurnAdmissionToken:
                return "缺少 TURN admission token"
            case .missingDeviceID:
                return "缺少 TURN 设备身份"
            case .networkError(let error):
                return "网络请求失败: \(error.localizedDescription)"
            case .invalidResponse(let message):
                return "无效的服务器响应: \(message)"
            case .serverError(let code, let message):
                return "服务器错误 (\(code)): \(message ?? "未知错误")"
            case .decodingFailed(let error):
                return "凭据解析失败: \(error.localizedDescription)"
            case .refreshRequiresNewTurnAdmissionToken:
                return "TURN admission token 为一次性租约，刷新需要新的租约"
            }
        }
    }

    public func getCredentials(
        sessionID: String,
        turnAdmissionLease: SignalServerClient.TurnAdmissionLease?
    ) async -> TURNCredentials {
        let allowStaticTURNFallback = allowStaticTURNFallbackProvider()
        if let cached = cachedCredentialsBySessionID[sessionID],
           cached.credentials.isValid(buffer: expirationBuffer) {
            logger.debug("📦 使用缓存的 TURN 凭据 session=\(RemoteConnectionLogRedaction.session(sessionID), privacy: .public)")
            return cached.credentials
        }

        guard let turnAdmissionLease else {
            logger.warning(
                "⚠️ 缺少 TURN admission lease，降级为\(allowStaticTURNFallback ? "显式允许的静态 TURN/空凭据" : "STUN-only")"
            )
            return fallbackCredentials(allowStaticTURN: allowStaticTURNFallback)
        }

        let trimmedToken = turnAdmissionLease.token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let cached = cachedCredentialsBySessionID[sessionID],
           cached.turnAdmissionToken == trimmedToken {
            logger.warning(
                "⚠️ TURN admission token 已消费且无法刷新 session=\(RemoteConnectionLogRedaction.session(sessionID), privacy: .public)，请重新申请会话租约"
            )
            if cached.credentials.isValid(buffer: 0) {
                return cached.credentials
            }
            return fallbackCredentials(allowStaticTURN: allowStaticTURNFallback)
        }

        do {
            let fresh = try await fetchFromServer(turnAdmissionToken: trimmedToken)
            cachedCredentialsBySessionID[sessionID] = CachedTurnEntry(
                credentials: fresh,
                turnAdmissionToken: trimmedToken
            )
            logger.info("✅ 获取到新的 TURN 凭据 session=\(RemoteConnectionLogRedaction.session(sessionID), privacy: .public) ttl=\(fresh.ttl)")
            return fresh
        } catch {
            if let cached = cachedCredentialsBySessionID[sessionID],
               cached.credentials.isValid(buffer: 0) {
                logger.warning(
                    "⚠️ 动态 TURN 凭据获取失败，继续复用刚过刷新窗口的缓存凭据 session=\(RemoteConnectionLogRedaction.session(sessionID), privacy: .public): \(RemoteConnectionLogRedaction.error(error), privacy: .public)"
                )
                return cached.credentials
            }
            logger.warning(
                "⚠️ 动态 TURN 凭据获取失败，降级为\(allowStaticTURNFallback ? "显式允许的静态 TURN/空凭据" : "STUN-only"): \(RemoteConnectionLogRedaction.error(error), privacy: .public)"
            )
            return fallbackCredentials(allowStaticTURN: allowStaticTURNFallback)
        }
    }

    public func refreshCredentials(
        sessionID: String,
        turnAdmissionLease: SignalServerClient.TurnAdmissionLease?
    ) async throws -> TURNCredentials {
        guard let turnAdmissionLease else {
            throw TURNCredentialError.missingTurnAdmissionToken
        }
        let trimmedToken = turnAdmissionLease.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw TURNCredentialError.missingTurnAdmissionToken
        }
        if let cached = cachedCredentialsBySessionID[sessionID],
           cached.turnAdmissionToken == trimmedToken {
            if cached.credentials.isValid(buffer: 0) {
                return cached.credentials
            }
            throw TURNCredentialError.refreshRequiresNewTurnAdmissionToken
        }

        let fresh = try await fetchFromServer(turnAdmissionToken: trimmedToken)
        cachedCredentialsBySessionID[sessionID] = CachedTurnEntry(
            credentials: fresh,
            turnAdmissionToken: trimmedToken
        )
        return fresh
    }

    /// Formal interoperability uses this fail-closed entry point: it neither falls back to
    /// process-wide static credentials nor converts a credential-service failure to STUN-only.
    func requireCredentials(
        sessionID: String,
        turnAdmissionLease: SignalServerClient.TurnAdmissionLease?
    ) async throws -> TURNCredentials {
        if let cached = cachedCredentialsBySessionID[sessionID],
           cached.credentials.isValid(buffer: expirationBuffer) {
            return cached.credentials
        }
        guard let turnAdmissionLease else {
            throw TURNCredentialError.missingTurnAdmissionToken
        }
        let trimmedToken = turnAdmissionLease.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw TURNCredentialError.missingTurnAdmissionToken
        }
        if let cached = cachedCredentialsBySessionID[sessionID],
           cached.turnAdmissionToken == trimmedToken {
            if cached.credentials.isValid(buffer: 0) {
                return cached.credentials
            }
            throw TURNCredentialError.refreshRequiresNewTurnAdmissionToken
        }

        let fresh = try await fetchFromServer(turnAdmissionToken: trimmedToken)
        let username = fresh.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = fresh.password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, !password.isEmpty, !fresh.uris.isEmpty else {
            throw TURNCredentialError.invalidResponse("TURN credentials are incomplete")
        }
        cachedCredentialsBySessionID[sessionID] = CachedTurnEntry(
            credentials: fresh,
            turnAdmissionToken: trimmedToken
        )
        return fresh
    }

    func testingRequest(turnAdmissionToken: String) async throws -> URLRequest {
        try await makeRequest(turnAdmissionToken: turnAdmissionToken)
    }

    struct URLSessionPolicySnapshot: Sendable, Equatable {
        let hasURLCache: Bool
        let requestCachePolicyRawValue: UInt
        let hasHTTPCookieStorage: Bool
        let httpShouldSetCookies: Bool
        let hasURLCredentialStorage: Bool
    }

    func testingURLSessionPolicy() -> URLSessionPolicySnapshot {
        let configuration = urlSession.configuration
        return URLSessionPolicySnapshot(
            hasURLCache: configuration.urlCache != nil,
            requestCachePolicyRawValue: configuration.requestCachePolicy.rawValue,
            hasHTTPCookieStorage: configuration.httpCookieStorage != nil,
            httpShouldSetCookies: configuration.httpShouldSetCookies,
            hasURLCredentialStorage: configuration.urlCredentialStorage != nil
        )
    }

    public func clearCache(sessionID: String? = nil) {
        if let sessionID, !sessionID.isEmpty {
            cachedCredentialsBySessionID.removeValue(forKey: sessionID)
            logger.info("🗑️ TURN 凭据缓存已清除 session=\(RemoteConnectionLogRedaction.session(sessionID), privacy: .public)")
        } else {
            cachedCredentialsBySessionID.removeAll()
            logger.info("🗑️ 所有 TURN 凭据缓存已清除")
        }
    }

    private func fetchFromServer(turnAdmissionToken: String) async throws -> TURNCredentials {
        let request = try await makeRequest(turnAdmissionToken: turnAdmissionToken)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw TURNCredentialError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TURNCredentialError.invalidResponse("非 HTTP 响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let body = String(data: data, encoding: .utf8)
            throw TURNCredentialError.serverError(httpResponse.statusCode, body)
        }

        do {
            let serverResponse = try JSONDecoder().decode(ServerResponse.self, from: data)
            let ttl = max(60, serverResponse.ttl)
            let expiresAt: Date
            if let expiresAtEpoch = serverResponse.expiresAt, expiresAtEpoch > 0 {
                expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtEpoch))
            } else {
                expiresAt = Date().addingTimeInterval(TimeInterval(ttl))
            }
            let uris = SkyBridgeServerConfig.preferredTurnURIs(
                from: serverResponse.uris ?? [],
                fallback: fallbackTURNURLsProvider()
            )
            return TURNCredentials(
                username: serverResponse.username,
                password: serverResponse.password,
                ttl: ttl,
                uris: uris,
                expiresAt: expiresAt
            )
        } catch {
            throw TURNCredentialError.decodingFailed(error)
        }
    }

    private func makeRequest(turnAdmissionToken: String) async throws -> URLRequest {
        guard let endpoint = credentialEndpointProvider() else {
            throw TURNCredentialError.endpointNotConfigured
        }
        let trimmedToken = turnAdmissionToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw TURNCredentialError.missingTurnAdmissionToken
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(trimmedToken, forHTTPHeaderField: "X-SkyBridge-Turn-Admission")
        let apiKey = SkyBridgeServerConfig.clientAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !apiKey.isEmpty {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        let deviceID = await deviceIDProvider()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresDeviceID, deviceID.isEmpty {
            throw TURNCredentialError.missingDeviceID
        }
        if !deviceID.isEmpty {
            request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        }
        request.timeoutInterval = requestTimeout
        return request
    }

    static func resolvedFallbackCredentials(
        allowStaticTURN: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        turnURLs: [String] = SkyBridgeServerConfig.turnURLs,
        now: Date = Date()
    ) -> TURNCredentials {
        let expiresAt = now.addingTimeInterval(3600)

        guard allowStaticTURN else {
            return TURNCredentials(
                username: "",
                password: "",
                ttl: 3600,
                uris: [],
                expiresAt: expiresAt
            )
        }

        let username = (environment["SKYBRIDGE_TURN_USERNAME"] ?? SkyBridgeServerConfig.turnUsername)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let password = (environment["SKYBRIDGE_TURN_PASSWORD"] ?? SkyBridgeServerConfig.turnPassword)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, !password.isEmpty else {
            return TURNCredentials(
                username: "",
                password: "",
                ttl: 3600,
                uris: [],
                expiresAt: expiresAt
            )
        }

        return TURNCredentials(
            username: username,
            password: password,
            ttl: 3600,
            uris: turnURLs,
            expiresAt: expiresAt
        )
    }

    private func fallbackCredentials(allowStaticTURN: Bool) -> TURNCredentials {
        Self.resolvedFallbackCredentials(
            allowStaticTURN: allowStaticTURN,
            turnURLs: fallbackTURNURLsProvider()
        )
    }
}

extension SkyBridgeServerConfig {
    public static func dynamicICEConfig(
        sessionID: String,
        turnAdmissionLease: SignalServerClient.TurnAdmissionLease?,
        credentialService: TURNCredentialService = .shared
    ) async -> SkyBridgeICEConfiguration {
        let credentials = await credentialService.getCredentials(
            sessionID: sessionID,
            turnAdmissionLease: turnAdmissionLease
        )
        let turnUsername = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnPassword = credentials.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnURIs = preferredTurnURIs(from: credentials.uris, fallback: self.turnURLs)
        let shouldUseTURN = !turnUsername.isEmpty && !turnPassword.isEmpty && !turnURIs.isEmpty

        return SkyBridgeICEConfiguration(
            stunURL: stunURL,
            turnURLs: shouldUseTURN ? turnURIs : [],
            turnUsername: shouldUseTURN ? turnUsername : "",
            turnPassword: shouldUseTURN ? turnPassword : ""
        )
    }

    public static func dynamicICEConfig() async -> SkyBridgeICEConfiguration {
        await dynamicICEConfig(sessionID: "fallback", turnAdmissionLease: nil)
    }

    static func formalDynamicICEConfig(
        sessionID: String,
        turnAdmissionLease: SignalServerClient.TurnAdmissionLease?,
        credentialService: TURNCredentialService
    ) async throws -> SkyBridgeICEConfiguration {
        let credentials = try await credentialService.requireCredentials(
            sessionID: sessionID,
            turnAdmissionLease: turnAdmissionLease
        )
        return SkyBridgeICEConfiguration(
            stunURL: stunURL,
            turnURLs: credentials.uris,
            turnUsername: credentials.username.trimmingCharacters(in: .whitespacesAndNewlines),
            turnPassword: credentials.password.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
