import Foundation
import OSLog
import SkyBridgeProtocolCore

public actor TURNCredentialService {
    public static let shared = TURNCredentialService()

    private var credentialEndpoint: URL? {
        URL(string: "\(SkyBridgeServerConfig.signalingServerURL)/api/turn/credentials")
    }

    private var cachedCredentialsBySessionID: [String: TURNCredentials] = [:]
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
        case serverError(Int, String?)
        case decodingFailed(Error)

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
            case .serverError(let code, let message):
                return "服务器错误 (\(code)): \(message ?? "未知错误")"
            case .decodingFailed(let error):
                return "凭据解析失败: \(error.localizedDescription)"
            }
        }
    }

    public func getCredentials(
        sessionID: String,
        turnAdmissionLease: SignalServerClient.TurnAdmissionLease?
    ) async -> TURNCredentials {
        if let cached = cachedCredentialsBySessionID[sessionID], cached.isValid(buffer: expirationBuffer) {
            logger.debug("📦 使用缓存的 TURN 凭据 session=\(sessionID, privacy: .public)")
            return cached
        }

        guard let turnAdmissionLease else {
            logger.warning("⚠️ 缺少 TURN admission lease，降级为静态/空凭据")
            return fallbackCredentials()
        }

        do {
            let fresh = try await fetchFromServer(turnAdmissionToken: turnAdmissionLease.token)
            cachedCredentialsBySessionID[sessionID] = fresh
            logger.info("✅ 获取到新的 TURN 凭据 session=\(sessionID, privacy: .public) ttl=\(fresh.ttl)")
            return fresh
        } catch {
            logger.warning("⚠️ 动态 TURN 凭据获取失败，降级为静态/空凭据: \(error.localizedDescription, privacy: .public)")
            return fallbackCredentials()
        }
    }

    public func refreshCredentials(
        sessionID: String,
        turnAdmissionLease: SignalServerClient.TurnAdmissionLease?
    ) async throws -> TURNCredentials {
        cachedCredentialsBySessionID.removeValue(forKey: sessionID)
        guard let turnAdmissionLease else {
            throw TURNCredentialError.missingTurnAdmissionToken
        }
        let fresh = try await fetchFromServer(turnAdmissionToken: turnAdmissionLease.token)
        cachedCredentialsBySessionID[sessionID] = fresh
        return fresh
    }

    public func clearCache(sessionID: String? = nil) {
        if let sessionID, !sessionID.isEmpty {
            cachedCredentialsBySessionID.removeValue(forKey: sessionID)
            logger.info("🗑️ TURN 凭据缓存已清除 session=\(sessionID, privacy: .public)")
        } else {
            cachedCredentialsBySessionID.removeAll()
            logger.info("🗑️ 所有 TURN 凭据缓存已清除")
        }
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
        let deviceID = await DeviceIdentityKeyManager.shared.getDeviceId()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !deviceID.isEmpty {
            request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        }
        request.timeoutInterval = 10

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
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
                fallback: SkyBridgeServerConfig.turnURLs
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

    private func fallbackCredentials() -> TURNCredentials {
        let username = SkyBridgeServerConfig.turnUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let password = SkyBridgeServerConfig.turnPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, !password.isEmpty else {
            return TURNCredentials(
                username: "",
                password: "",
                ttl: 3600,
                uris: [],
                expiresAt: Date().addingTimeInterval(3600)
            )
        }

        return TURNCredentials(
            username: username,
            password: password,
            ttl: 3600,
            uris: SkyBridgeServerConfig.turnURLs,
            expiresAt: Date().addingTimeInterval(3600)
        )
    }
}

extension SkyBridgeServerConfig {
    public static func dynamicICEConfig(
        sessionID: String,
        turnAdmissionLease: SignalServerClient.TurnAdmissionLease?
    ) async -> SkyBridgeICEConfiguration {
        let credentials = await TURNCredentialService.shared.getCredentials(
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
}
