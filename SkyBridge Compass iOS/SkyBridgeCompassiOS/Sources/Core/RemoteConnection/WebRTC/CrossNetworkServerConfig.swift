import Foundation
import OSLog

@available(iOS 17.0, *)
enum CrossNetworkServerConfig {
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

    static var signalingWebSocketURL: String {
        environmentValue("SKYBRIDGE_SIGNALING_WEBSOCKET_URL", default: "wss://api.nebula-technologies.net/ws")
    }

    static var signalingServerURL: String {
        environmentValue("SKYBRIDGE_SIGNALING_SERVER_URL", default: "https://api.nebula-technologies.net")
    }

    static var stunURL: String {
        environmentValue("SKYBRIDGE_STUN_URL", default: "stun:54.92.79.99:3478")
    }

    static var turnURL: String {
        environmentValue("SKYBRIDGE_TURN_URL", default: "turn:54.92.79.99:3478?transport=udp")
    }

    static var turnTLSURL: String {
        environmentValue("SKYBRIDGE_TURN_TLS_URL", default: "turns:54.92.79.99:5349?transport=tcp")
    }

    static var turnURLs: [String] {
        environmentList("SKYBRIDGE_TURN_URLS", default: [turnTLSURL, turnURL])
    }

    static var clientAPIKey: String {
        ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_API_KEY"] ?? "skybridge-client-v1"
    }

    static var allowStaticTurnFallback: Bool {
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

    static func dynamicICEConfig(turnAdmissionToken: String?) async -> WebRTCSession.ICEConfig {
        let creds = await CrossNetworkTURNCredentialService.shared.getCredentials(turnAdmissionToken: turnAdmissionToken)
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

@available(iOS 17.0, *)
private actor CrossNetworkTURNCredentialService {
    static let shared = CrossNetworkTURNCredentialService()

    private let logger = Logger(subsystem: "com.skybridge.turn", category: "CrossNetwork-iOS")
    private var cachedByTokenKey: [String: TURNCredentials] = [:]
    private let minimumRefreshBuffer: TimeInterval = 10

    struct TURNCredentials: Sendable, Codable {
        let username: String
        let password: String
        let ttl: Int
        let uris: [String]
        let expiresAt: Date

        func isValid(buffer: TimeInterval) -> Bool {
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

    func getCredentials(turnAdmissionToken: String?) async -> TURNCredentials {
        let normalizedToken = normalizedTurnAdmissionToken(turnAdmissionToken)
        let tokenKey = cacheKey(for: normalizedToken)
        if let cached = cachedByTokenKey[tokenKey] {
            if cached.isValid(buffer: refreshBuffer(for: cached)) {
                return cached
            }
            if normalizedToken != nil {
                logger.info("ℹ️ TURN admission token is single-use; reusing cached credentials until expiry.")
                if cached.isValid(buffer: 0) {
                    return cached
                }
                logger.warning("⚠️ TURN admission token already consumed and cached credentials expired; falling back to STUN-only.")
                return fallback(allowStaticTURN: false)
            }
        }
        do {
            let fresh = try await fetchFromServer(turnAdmissionToken: normalizedToken)
            cachedByTokenKey[tokenKey] = fresh
            return fresh
        } catch {
            if let cached = cachedByTokenKey[tokenKey],
               cached.isValid(buffer: 0) {
                logger.info("ℹ️ TURN credentials fetch failed; reusing cached credentials. err=\(error.localizedDescription, privacy: .public)")
                return cached
            }
            let allowStaticTURN = normalizedToken == nil && CrossNetworkServerConfig.allowStaticTurnFallback
            logger.warning(
                "⚠️ TURN credentials fetch failed; falling back to \(allowStaticTURN ? "static-or-empty TURN" : "STUN-only"). err=\(error.localizedDescription, privacy: .public)"
            )
            return fallback(allowStaticTURN: allowStaticTURN)
        }
    }

    private func normalizedTurnAdmissionToken(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cacheKey(for turnAdmissionToken: String?) -> String {
        turnAdmissionToken ?? "__anonymous__"
    }

    private func refreshBuffer(for credentials: TURNCredentials) -> TimeInterval {
        min(30, max(minimumRefreshBuffer, TimeInterval(credentials.ttl) * 0.15))
    }

    private func fetchFromServer(turnAdmissionToken: String?) async throws -> TURNCredentials {
        guard let url = URL(string: "\(CrossNetworkServerConfig.signalingServerURL)/api/turn/credentials") else {
            throw URLError(.badURL)
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(CrossNetworkServerConfig.clientAPIKey, forHTTPHeaderField: "X-API-Key")
        if let turnAdmissionToken = turnAdmissionToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !turnAdmissionToken.isEmpty {
            req.setValue(turnAdmissionToken, forHTTPHeaderField: "X-SkyBridge-Turn-Admission")
        }
        let deviceId = try await resolvedDeviceIdentifier()
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.timeoutInterval = 10

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
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
        let uris = CrossNetworkServerConfig.preferredTurnURIs(
            from: decoded.uris ?? [],
            fallback: CrossNetworkServerConfig.turnURLs
        )
        return TURNCredentials(
            username: decoded.username,
            password: decoded.password,
            ttl: ttl,
            uris: uris,
            expiresAt: expiresAt
        )
    }

    private func fallback(allowStaticTURN: Bool = true) -> TURNCredentials {
        guard allowStaticTURN else {
            return TURNCredentials(
                username: "",
                password: "",
                ttl: 3600,
                uris: [],
                expiresAt: Date().addingTimeInterval(3600)
            )
        }

        // Safe fallback: do not embed secrets in the app.
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
            uris: CrossNetworkServerConfig.turnURLs,
            expiresAt: Date().addingTimeInterval(3600)
        )
    }

    private func resolvedDeviceIdentifier() async throws -> String {
        try await SkyBridgeiOSCore.shared.currentProtocolIdentitySnapshot().deviceId
    }
}
