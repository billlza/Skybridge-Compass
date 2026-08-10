import Foundation
import CryptoKit
import OSLog
import SkyBridgeProtocolCore

public actor TURNCredentialService {
    public static let shared = TURNCredentialService()

    private var credentialEndpoint: URL? {
        URL(string: "\(SkyBridgeServerConfig.signalingServerURL)/api/turn/credentials")
    }

    private struct CachedTurnEntry: Sendable {
        let credentials: TURNCredentials
        let turnAdmissionTokenDigest: Data
    }

    private var cachedCredentialsBySessionID: [String: CachedTurnEntry] = [:]
    private var activeRequestDigestBySessionID: [String: Data] = [:]
    private let maximumCachedSessions = 128
    private let maximumResponseBytes = 64 * 1024
    private let minimumUsableLifetime: TimeInterval = 10
    private let expirationBuffer: TimeInterval = 30
    private let logger = Logger(subsystem: "com.skybridge.turn", category: "CredentialService")

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

    typealias CredentialFetcher = @Sendable (String) async throws -> TURNCredentials

    private let injectedCredentialFetcher: CredentialFetcher?

    init() {
        injectedCredentialFetcher = nil
    }

    init(credentialFetcher: @escaping CredentialFetcher) {
        injectedCredentialFetcher = credentialFetcher
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
        case networkError(Error)
        case invalidResponse(String)
        case serverError(statusCode: Int, responseBytes: Int)
        case decodingFailed(Error)
        case refreshRequiresNewTurnAdmissionToken
        case requestSuperseded

        public var errorDescription: String? {
            switch self {
            case .endpointNotConfigured:
                return "TURN 凭据端点未配置"
            case .missingTurnAdmissionToken:
                return "缺少 TURN admission token"
            case .networkError(let error):
                return "网络请求失败: \(error.localizedDescription)"
            case .invalidResponse(let message):
                return "无效的服务器响应: \(message)"
            case .serverError(let statusCode, let responseBytes):
                return "TURN 凭据服务器返回 HTTP \(statusCode)（响应 \(responseBytes) 字节）"
            case .decodingFailed(let error):
                return "凭据解析失败: \(error.localizedDescription)"
            case .refreshRequiresNewTurnAdmissionToken:
                return "TURN admission token 为一次性租约，刷新需要新的租约"
            case .requestSuperseded:
                return "TURN 凭据请求已被同一会话的更新租约取代"
            }
        }
    }

    public func getCredentials(
        sessionID: String,
        turnAdmissionLease: SignalServerClient.TurnAdmissionLease?
    ) async throws -> TURNCredentials {
        let allowStaticTURNFallback = SkyBridgeServerConfig.allowStaticTURNFallback
        guard let turnAdmissionLease else {
            guard allowStaticTURNFallback else {
                throw TURNCredentialError.missingTurnAdmissionToken
            }
            let fallback = fallbackCredentials(allowStaticTURN: true)
            guard Self.hasUsableCredentials(fallback) else {
                throw TURNCredentialError.invalidResponse("显式静态 TURN 配置缺少可用 URI 或凭据")
            }
            logger.warning("⚠️ 缺少 TURN admission lease，使用显式允许且已校验的静态 TURN 配置")
            return fallback
        }

        let trimmedToken = turnAdmissionLease.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedToken.isEmpty else {
            throw TURNCredentialError.missingTurnAdmissionToken
        }
        let tokenDigest = Self.tokenDigest(trimmedToken)
        activeRequestDigestBySessionID[sessionID] = tokenDigest
        if let cached = cachedCredentialsBySessionID[sessionID],
           cached.turnAdmissionTokenDigest == tokenDigest {
            if cached.credentials.isValid(buffer: expirationBuffer) {
                finishRequest(sessionID: sessionID, tokenDigest: tokenDigest)
                logger.debug("📦 使用绑定当前 TURN admission lease 的缓存凭据 session=\(sessionID, privacy: .public)")
                return cached.credentials
            }
            logger.warning(
                "⚠️ TURN admission token 已消费且无法刷新 session=\(sessionID, privacy: .public)，请重新申请会话租约"
            )
            if cached.credentials.isValid(buffer: 0) {
                finishRequest(sessionID: sessionID, tokenDigest: tokenDigest)
                return cached.credentials
            }
            finishRequest(sessionID: sessionID, tokenDigest: tokenDigest)
            throw TURNCredentialError.refreshRequiresNewTurnAdmissionToken
        }

        do {
            let fresh = try await fetchCredentials(turnAdmissionToken: trimmedToken)
            try requireCurrentRequest(sessionID: sessionID, tokenDigest: tokenDigest)
            storeCachedEntry(CachedTurnEntry(
                credentials: fresh,
                turnAdmissionTokenDigest: tokenDigest
            ), sessionID: sessionID)
            finishRequest(sessionID: sessionID, tokenDigest: tokenDigest)
            logger.info("✅ 获取到新的 TURN 凭据 session=\(sessionID, privacy: .public) ttl=\(fresh.ttl)")
            return fresh
        } catch {
            try requireCurrentRequest(sessionID: sessionID, tokenDigest: tokenDigest)
            finishRequest(sessionID: sessionID, tokenDigest: tokenDigest)
            if let cached = cachedCredentialsBySessionID[sessionID],
               cached.turnAdmissionTokenDigest == tokenDigest,
               cached.credentials.isValid(buffer: 0) {
                logger.warning(
                    "⚠️ 动态 TURN 凭据获取失败，继续复用刚过刷新窗口的缓存凭据 session=\(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return cached.credentials
            }
            logger.error(
                "❌ 动态 TURN 凭据获取失败且无可用缓存 session=\(sessionID, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
            throw error
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
        let tokenDigest = Self.tokenDigest(trimmedToken)
        activeRequestDigestBySessionID[sessionID] = tokenDigest
        if let cached = cachedCredentialsBySessionID[sessionID],
           cached.turnAdmissionTokenDigest == tokenDigest {
            if cached.credentials.isValid(buffer: 0) {
                finishRequest(sessionID: sessionID, tokenDigest: tokenDigest)
                return cached.credentials
            }
            finishRequest(sessionID: sessionID, tokenDigest: tokenDigest)
            throw TURNCredentialError.refreshRequiresNewTurnAdmissionToken
        }

        do {
            let fresh = try await fetchCredentials(turnAdmissionToken: trimmedToken)
            try requireCurrentRequest(sessionID: sessionID, tokenDigest: tokenDigest)
            storeCachedEntry(CachedTurnEntry(
                credentials: fresh,
                turnAdmissionTokenDigest: tokenDigest
            ), sessionID: sessionID)
            finishRequest(sessionID: sessionID, tokenDigest: tokenDigest)
            return fresh
        } catch {
            try requireCurrentRequest(sessionID: sessionID, tokenDigest: tokenDigest)
            finishRequest(sessionID: sessionID, tokenDigest: tokenDigest)
            throw error
        }
    }

    private func storeCachedEntry(_ entry: CachedTurnEntry, sessionID: String) {
        if cachedCredentialsBySessionID[sessionID] == nil,
           cachedCredentialsBySessionID.count >= maximumCachedSessions,
           let evictionSessionID = cachedCredentialsBySessionID.min(by: {
               $0.value.credentials.expiresAt < $1.value.credentials.expiresAt
           })?.key {
            cachedCredentialsBySessionID.removeValue(forKey: evictionSessionID)
        }
        cachedCredentialsBySessionID[sessionID] = entry
    }

    nonisolated private static func tokenDigest(_ token: String) -> Data {
        Data(SHA256.hash(data: Data(token.utf8)))
    }

    private func requireCurrentRequest(
        sessionID: String,
        tokenDigest: Data
    ) throws(TURNCredentialError) {
        guard activeRequestDigestBySessionID[sessionID] == tokenDigest else {
            throw TURNCredentialError.requestSuperseded
        }
    }

    private func finishRequest(sessionID: String, tokenDigest: Data) {
        guard activeRequestDigestBySessionID[sessionID] == tokenDigest else { return }
        activeRequestDigestBySessionID.removeValue(forKey: sessionID)
    }

    @discardableResult
    func clearCache(
        sessionID: String,
        ifBoundTo turnAdmissionLease: SignalServerClient.TurnAdmissionLease
    ) -> Bool {
        let trimmedToken = turnAdmissionLease.token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sessionID.isEmpty, !trimmedToken.isEmpty else {
            return false
        }
        let expectedDigest = Self.tokenDigest(trimmedToken)
        var didInvalidateBoundState = false
        if activeRequestDigestBySessionID[sessionID] == expectedDigest {
            activeRequestDigestBySessionID.removeValue(forKey: sessionID)
            didInvalidateBoundState = true
        }
        if cachedCredentialsBySessionID[sessionID]?.turnAdmissionTokenDigest == expectedDigest {
            cachedCredentialsBySessionID.removeValue(forKey: sessionID)
            didInvalidateBoundState = true
        }
        guard didInvalidateBoundState else {
            logger.debug(
                "ℹ️ TURN 凭据缓存条件清理跳过：会话租约已更替或缓存不存在 session=\(sessionID, privacy: .public)"
            )
            return false
        }
        logger.info("🗑️ TURN 凭据缓存已按精确租约清除 session=\(sessionID, privacy: .public)")
        return true
    }

    public func clearCache(sessionID: String? = nil) {
        if let sessionID, !sessionID.isEmpty {
            cachedCredentialsBySessionID.removeValue(forKey: sessionID)
            activeRequestDigestBySessionID.removeValue(forKey: sessionID)
            logger.info("🗑️ TURN 凭据缓存已清除 session=\(sessionID, privacy: .public)")
        } else {
            cachedCredentialsBySessionID.removeAll()
            activeRequestDigestBySessionID.removeAll()
            logger.info("🗑️ 所有 TURN 凭据缓存已清除")
        }
    }

    private func fetchCredentials(turnAdmissionToken: String) async throws -> TURNCredentials {
        if let injectedCredentialFetcher {
            return try await injectedCredentialFetcher(turnAdmissionToken)
        }
        return try await fetchFromServer(turnAdmissionToken: turnAdmissionToken)
    }

    private func fetchFromServer(turnAdmissionToken: String) async throws -> TURNCredentials {
        guard let endpoint = credentialEndpoint else {
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
        let deviceID = try await DeviceIdentityKeyManager.shared.getDeviceId()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !deviceID.isEmpty {
            request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        }
        request.timeoutInterval = 10

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw TURNCredentialError.networkError(error)
        }
        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, 4_096))
        do {
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw TURNCredentialError.invalidResponse("TURN 响应超过大小上限")
                }
                data.append(byte)
            }
        } catch let error as TURNCredentialError {
            throw error
        } catch {
            throw TURNCredentialError.networkError(error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TURNCredentialError.invalidResponse("非 HTTP 响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            // Error bodies can contain echoed credentials, tokens, proxy
            // diagnostics or HTML. Preserve only bounded structural metadata.
            throw TURNCredentialError.serverError(
                statusCode: httpResponse.statusCode,
                responseBytes: data.count
            )
        }

        do {
            let serverResponse = try JSONDecoder().decode(ServerResponse.self, from: data)
            guard serverResponse.ttl > 0 else {
                throw TURNCredentialError.invalidResponse("TURN TTL 必须大于 0")
            }
            let ttl = serverResponse.ttl
            let now = Date()
            let ttlExpiresAt = now.addingTimeInterval(TimeInterval(ttl))
            let serverExpiresAt: Date
            if let expiresAtEpoch = serverResponse.expiresAt, expiresAtEpoch > 0 {
                serverExpiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtEpoch))
            } else {
                serverExpiresAt = ttlExpiresAt
            }
            let expiresAt = min(serverExpiresAt, ttlExpiresAt)
            guard expiresAt.timeIntervalSince(now) >= minimumUsableLifetime else {
                throw TURNCredentialError.invalidResponse("TURN 凭据剩余寿命不足以启动 ICE")
            }
            let uris = SkyBridgeServerConfig.preferredTurnURIs(
                from: serverResponse.uris ?? [],
                fallback: SkyBridgeServerConfig.turnURLs
            )
            let credentials = TURNCredentials(
                username: serverResponse.username,
                password: serverResponse.password,
                ttl: ttl,
                uris: uris,
                expiresAt: expiresAt
            )
            guard Self.hasUsableCredentials(credentials) else {
                throw TURNCredentialError.invalidResponse("TURN 响应缺少可用 URI 或凭据")
            }
            return credentials
        } catch let error as TURNCredentialError {
            throw error
        } catch {
            throw TURNCredentialError.decodingFailed(error)
        }
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
        Self.resolvedFallbackCredentials(allowStaticTURN: allowStaticTURN)
    }

    nonisolated private static func hasUsableCredentials(_ credentials: TURNCredentials) -> Bool {
        credentials.isValid(buffer: 0)
            && !credentials.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !SkyBridgeServerConfig.normalizedTurnURIs(credentials.uris).isEmpty
    }
}

extension SkyBridgeServerConfig {
    public static func dynamicICEConfig(
        sessionID: String,
        turnAdmissionLease: SignalServerClient.TurnAdmissionLease?
    ) async throws -> SkyBridgeICEConfiguration {
        let credentials = try await TURNCredentialService.shared.getCredentials(
            sessionID: sessionID,
            turnAdmissionLease: turnAdmissionLease
        )
        let turnUsername = credentials.username.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnPassword = credentials.password.trimmingCharacters(in: .whitespacesAndNewlines)
        let turnURIs = preferredTurnURIs(from: credentials.uris, fallback: self.turnURLs)
        let shouldUseTURN = !turnUsername.isEmpty && !turnPassword.isEmpty && !turnURIs.isEmpty
        guard shouldUseTURN else {
            throw TURNCredentialService.TURNCredentialError.invalidResponse(
                "TURN 凭据解析后不可用于 ICE"
            )
        }

        return SkyBridgeICEConfiguration(
            stunURL: stunURL,
            turnURLs: turnURIs,
            turnUsername: turnUsername,
            turnPassword: turnPassword
        )
    }

    public static func dynamicICEConfig() async throws -> SkyBridgeICEConfiguration {
        try await dynamicICEConfig(sessionID: "fallback", turnAdmissionLease: nil)
    }
}
