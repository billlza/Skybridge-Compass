import Foundation
import OSLog

/// iOS target local server config (kept minimal on purpose).
///
/// Note:
/// - The SwiftPM `Sources/SkyBridgeCore/Config/ServerConfig.swift` is not necessarily compiled into the iOS app target.
/// - We keep iOS network endpoints here to avoid cross-target build issues.
@available(iOS 17.0, *)
public enum SkyBridgeServerConfig {
    private static let truthyConfigValues: Set<String> = ["1", "true", "yes", "on"]

    private static func environmentValue(_ name: String) -> String? {
        guard let raw = ProcessInfo.processInfo.environment[name] else { return nil }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func environmentValue(_ name: String, default defaultValue: String) -> String {
        guard let value = environmentValue(name), !value.isEmpty else { return defaultValue }
        return value
    }

    private static func environmentList(_ name: String, default defaultValue: [String]) -> [String] {
        guard let raw = ProcessInfo.processInfo.environment[name] else {
            return defaultValue
        }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // Production endpoints
    public static var signalingServerURL: String {
        environmentValue("SKYBRIDGE_SIGNALING_SERVER_URL", default: "https://api.nebula-technologies.net")
    }

    public static var signalingWebSocketURL: String {
        environmentValue("SKYBRIDGE_SIGNALING_WEBSOCKET_URL", default: "wss://api.nebula-technologies.net/ws")
    }

    // STUN/TURN hosts (Cloudflare doesn't proxy UDP, so these are direct)
    public static var stunURL: String {
        environmentValue("SKYBRIDGE_STUN_URL", default: "stun:54.92.79.99:3478")
    }

    public static var turnURL: String {
        environmentValue("SKYBRIDGE_TURN_URL", default: "turn:54.92.79.99:3478?transport=udp")
    }

    public static var turnTLSURL: String {
        environmentValue("SKYBRIDGE_TURN_TLS_URL", default: "turns:54.92.79.99:5349?transport=tcp")
    }

    public static var turnURLs: [String] {
        environmentList("SKYBRIDGE_TURN_URLS", default: [turnTLSURL, turnURL])
    }

    /// Nebula auth configuration uses the same keys as macOS for future parity.
    /// Native clients should avoid shipping long-lived secrets in production builds.
    public static var nebulaBaseURL: String? {
        NebulaConfigurationResolver.resolve()?.baseURL
    }

    public static var nebulaClientID: String? {
        NebulaConfigurationResolver.resolve()?.clientId
    }

    public static var nebulaClientSecret: String? {
        NebulaConfigurationResolver.resolve()?.clientSecret
    }

    public static var hasNebulaConfiguration: Bool {
        NebulaConfigurationResolver.resolve() != nil
    }

    /// Client API key used for requesting dynamic TURN credentials.
    /// This is NOT a secret; it's only used to tag legitimate client traffic.
    public static var clientAPIKey: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_API_KEY"] ?? "skybridge-client-v1"
    }

    /// Static TURN credentials are an emergency rollback path only.
    /// Production defaults must stay fail-closed unless this is explicitly enabled.
    public static var allowStaticTurnFallback: Bool {
        if let value = environmentValue("SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK") {
            return truthyConfigValues.contains(value.lowercased())
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK") as? Bool {
            return value
        }
        if let value = Bundle.main.object(forInfoDictionaryKey: "SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK") as? String {
            return truthyConfigValues.contains(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        }
        return false
    }

    /// Fetch short-lived TURN credentials (with safe fallback).
    public static func dynamicICEConfig() async -> WebRTCSession.ICEConfig {
        let creds = await TURNCredentialService.shared.getCredentials()
        let turnUsername = normalizedValue(creds.username)
        let turnPassword = normalizedValue(creds.password)
        let turnURIs = preferredTurnURIs(from: creds.uris, fallback: turnURLs)
        let shouldUseTURN = !turnUsername.isEmpty && !turnPassword.isEmpty && !turnURIs.isEmpty

        return WebRTCSession.ICEConfig(
            stunURL: stunURL,
            turnURLs: shouldUseTURN ? turnURIs : [],
            turnUsername: shouldUseTURN ? turnUsername : "",
            turnPassword: shouldUseTURN ? turnPassword : ""
        )
    }

    private static func normalizedValue(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    fileprivate static func normalizedTurnURIs(_ uris: [String]) -> [String] {
        var seen = Set<String>()
        return uris
            .map { normalizedValue($0) }
            .filter { uri in
                let lower = uri.lowercased()
                guard lower.hasPrefix("turn:") || lower.hasPrefix("turns:") else {
                    return false
                }
                if seen.contains(lower) {
                    return false
                }
                seen.insert(lower)
                return true
            }
    }

    fileprivate static func turnPriority(_ uri: String) -> Int {
        let lower = uri.lowercased()
        if lower.hasPrefix("turns:") { return 0 }
        if lower.contains("transport=tcp") { return 1 }
        return 2
    }

    fileprivate static func preferredTurnURIs(from uris: [String], fallback: [String]) -> [String] {
        let candidates = normalizedTurnURIs(uris)
        let effective = candidates.isEmpty ? normalizedTurnURIs(fallback) : candidates
        return effective
            .enumerated()
            .sorted { lhs, rhs in
                let lp = turnPriority(lhs.element)
                let rp = turnPriority(rhs.element)
                if lp == rp { return lhs.offset < rhs.offset }
                return lp < rp
            }
            .map(\.element)
    }
}

private enum NebulaConfigurationResolver {
    struct ResolvedConfiguration: Sendable, Equatable {
        let baseURL: String
        let clientId: String
        let clientSecret: String?
    }

    static func resolve(bundle: Bundle = .main) -> ResolvedConfiguration? {
        guard let baseURL = resolvedValue("NEBULA_BASE_URL", bundle: bundle, validator: isValidBaseURL),
              let clientId = resolvedValue("NEBULA_CLIENT_ID", bundle: bundle) else {
            return nil
        }

        let clientSecret = resolvedValue("NEBULA_CLIENT_SECRET", bundle: bundle)

        return ResolvedConfiguration(
            baseURL: baseURL,
            clientId: clientId,
            clientSecret: clientSecret
        )
    }

    private static func resolvedValue(
        _ key: String,
        bundle: Bundle,
        validator: (String) -> Bool = { !$0.isEmpty }
    ) -> String? {
        if let value = normalizedKeychainValue(forKey: key),
           !isPlaceholder(value, key: key),
           validator(value) {
            return value
        }

        if let value = normalized(ProcessInfo.processInfo.environment[key]),
           !isPlaceholder(value, key: key),
           validator(value) {
            return value
        }

        if let value = normalized(bundle.object(forInfoDictionaryKey: key) as? String),
           !isPlaceholder(value, key: key),
           validator(value) {
            return value
        }

        return nil
    }

    private static func normalizedKeychainValue(forKey key: String) -> String? {
        guard let config = try? KeychainManager.shared.retrieveNebulaConfig() else {
            return nil
        }

        switch key {
        case "NEBULA_BASE_URL":
            return normalized(config.baseURL)
        case "NEBULA_CLIENT_ID":
            return normalized(config.clientId)
        case "NEBULA_CLIENT_SECRET":
            return normalized(config.clientSecret)
        default:
            return nil
        }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isValidBaseURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = url.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    private static func isPlaceholder(_ value: String, key: String) -> Bool {
        let lowered = value.lowercased()
        switch key {
        case "NEBULA_BASE_URL":
            return lowered.contains("your-nebula-host") || lowered.contains("example.com")
        case "NEBULA_CLIENT_ID":
            return lowered == "your-nebula-client-id"
        case "NEBULA_CLIENT_SECRET":
            return lowered == "your-nebula-client-secret"
        default:
            return false
        }
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
        let expiresAt: Int?
        let mode: String?
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
            let allowStaticTURN = SkyBridgeServerConfig.allowStaticTurnFallback
            logger.warning(
                "⚠️ TURN credentials fetch failed, falling back to \(allowStaticTURN ? "static-or-empty TURN" : "STUN-only"). err=\(error.localizedDescription, privacy: .public)"
            )
            return fallbackCredentials(allowStaticTURN: allowStaticTURN)
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
        if let deviceId = resolvedDeviceIdentifier() {
            request.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        }
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let instance = http.value(forHTTPHeaderField: "X-SkyBridge-Instance") ?? "unknown"
        let backend = http.value(forHTTPHeaderField: "X-SkyBridge-State-Backend") ?? "unknown"
        let prefixes = http.value(forHTTPHeaderField: "X-SkyBridge-Code-Prefixes") ?? "-"
        logger.info("🌐 TURN credentials served by instance=\(instance, privacy: .public) backend=\(backend, privacy: .public) prefixes=\(prefixes, privacy: .public)")
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "TURN", code: http.statusCode, userInfo: ["body": body])
        }
        let decoded = try JSONDecoder().decode(ServerResponse.self, from: data)
        let ttl = max(60, decoded.ttl)
        let expiresAt: Date
        if let expiresAtEpoch = decoded.expiresAt, expiresAtEpoch > 0 {
            expiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtEpoch))
        } else {
            expiresAt = Date().addingTimeInterval(TimeInterval(ttl))
        }
        let uris = SkyBridgeServerConfig.preferredTurnURIs(from: decoded.uris ?? [], fallback: SkyBridgeServerConfig.turnURLs)
        return TURNCredentials(
            username: decoded.username,
            password: decoded.password,
            ttl: ttl,
            uris: uris,
            expiresAt: expiresAt
        )
    }

    private func fallbackCredentials(allowStaticTURN: Bool) -> TURNCredentials {
        guard allowStaticTURN else {
            logger.warning("⚠️ Static TURN fallback is disabled; using STUN-only.")
            return TURNCredentials(
                username: "",
                password: "",
                ttl: 3600,
                uris: [],
                expiresAt: Date().addingTimeInterval(3600)
            )
        }

        // Static TURN is an explicit rollback path only.
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
            uris: SkyBridgeServerConfig.turnURLs,
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    private func resolvedDeviceIdentifier() -> String? {
        let envID = ProcessInfo.processInfo.environment["SKYBRIDGE_DEVICE_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !envID.isEmpty {
            return envID
        }
        let keychainID = KeychainManager.shared.getOrGenerateDeviceId()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return keychainID.isEmpty ? nil : keychainID
    }
}
