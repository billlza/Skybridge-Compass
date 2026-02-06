import Foundation
import OSLog

/// iOS target local server config (kept minimal on purpose).
///
/// Note:
/// - The SwiftPM `Sources/SkyBridgeCore/Config/ServerConfig.swift` is not necessarily compiled into the iOS app target.
/// - We keep iOS network endpoints here to avoid cross-target build issues.
@available(iOS 17.0, *)
public enum SkyBridgeServerConfig {
    // Production endpoints
    public static let signalingServerURL = "https://api.nebula-technologies.net"
    public static let signalingWebSocketURL = "wss://api.nebula-technologies.net/ws"

    // STUN/TURN hosts (Cloudflare doesn't proxy UDP, so these are direct)
    public static let stunURL = "stun:54.92.79.99:3478"
    public static let turnURL = "turn:54.92.79.99:3478"

    /// Client API key used for requesting dynamic TURN credentials.
    /// This is NOT a secret; it's only used to tag legitimate client traffic.
    public static var clientAPIKey: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_API_KEY"] ?? "skybridge-client-v1"
    }

    /// Fetch short-lived TURN credentials (with safe fallback).
    public static func dynamicICEConfig() async -> WebRTCSession.ICEConfig {
        let creds = await TURNCredentialService.shared.getCredentials()
        let turnUsername = normalizedValue(creds.username)
        let turnPassword = normalizedValue(creds.password)
        let turnURL = firstValidTurnURI(from: creds.uris) ?? self.turnURL
        let shouldUseTURN = !turnUsername.isEmpty && !turnPassword.isEmpty

        return WebRTCSession.ICEConfig(
            stunURL: stunURL,
            turnURL: shouldUseTURN ? turnURL : "",
            turnUsername: shouldUseTURN ? turnUsername : "",
            turnPassword: shouldUseTURN ? turnPassword : ""
        )
    }

    private static func normalizedValue(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstValidTurnURI(from uris: [String]) -> String? {
        uris
            .map { normalizedValue($0) }
            .first { $0.hasPrefix("turn:") || $0.hasPrefix("turns:") }
    }
}

// MARK: - TURN dynamic credential service (iOS-local)

@available(iOS 17.0, *)
public actor TURNCredentialService {
    public static let shared = TURNCredentialService()

    private let logger = Logger(subsystem: "com.skybridge.turn", category: "CredentialService-iOS")

    private var cachedCredentials: TURNCredentials?
    private let expirationBuffer: TimeInterval = 300 // refresh 5 minutes early

    private var credentialEndpoint: URL? {
        URL(string: "\(SkyBridgeServerConfig.signalingServerURL)/api/turn/credentials")
    }

    public struct TURNCredentials: Sendable, Codable {
        public let username: String
        public let password: String
        public let ttl: Int
        public let uris: [String]
        public let expiresAt: Date

        public func isValid(buffer: TimeInterval = 300) -> Bool {
            Date().addingTimeInterval(buffer) < expiresAt
        }
    }

    private struct ServerResponse: Codable {
        let username: String
        let password: String
        let ttl: Int
        let uris: [String]?
    }

    public func getCredentials() async -> TURNCredentials {
        if let cached = cachedCredentials, cached.isValid(buffer: expirationBuffer) {
            return cached
        }
        do {
            let fresh = try await fetchFromServer()
            cachedCredentials = fresh
            return fresh
        } catch {
            logger.warning("⚠️ TURN credentials fetch failed, falling back. err=\(error.localizedDescription, privacy: .public)")
            return fallbackCredentials()
        }
    }

    private func fetchFromServer() async throws -> TURNCredentials {
        guard let endpoint = credentialEndpoint else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(SkyBridgeServerConfig.clientAPIKey, forHTTPHeaderField: "X-API-Key")
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TURN", code: http.statusCode, userInfo: ["body": body])
        }
        let decoded = try JSONDecoder().decode(ServerResponse.self, from: data)
        let expiresAt = Date().addingTimeInterval(TimeInterval(decoded.ttl))
        return TURNCredentials(
            username: decoded.username,
            password: decoded.password,
            ttl: decoded.ttl,
            uris: decoded.uris ?? [SkyBridgeServerConfig.turnURL],
            expiresAt: expiresAt
        )
    }

    private func fallbackCredentials() -> TURNCredentials {
        // Safe fallback: keep connectivity without embedding secrets.
        // NOTE: turn password comes from env (should be empty in production builds).
        let username = (ProcessInfo.processInfo.environment["SKYBRIDGE_TURN_USERNAME"] ?? "skybridge")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let password = (ProcessInfo.processInfo.environment["SKYBRIDGE_TURN_PASSWORD"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !username.isEmpty, !password.isEmpty else {
            logger.warning("⚠️ TURN fallback credentials incomplete, will use STUN-only.")
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
            uris: [SkyBridgeServerConfig.turnURL],
            expiresAt: Date().addingTimeInterval(3600)
        )
    }
}

