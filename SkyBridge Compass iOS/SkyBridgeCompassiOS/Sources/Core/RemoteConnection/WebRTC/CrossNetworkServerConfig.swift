import Foundation
import CryptoKit
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

    static func dynamicICEConfig(turnAdmissionToken: String?) async throws -> WebRTCSession.ICEConfig {
        let creds = try await CrossNetworkTURNCredentialService.shared.getCredentials(
            turnAdmissionToken: turnAdmissionToken
        )
        let turnUsername = normalizedValue(creds.username)
        let turnPassword = normalizedValue(creds.password)
        let turnURIs = preferredTurnURIs(from: creds.uris, fallback: turnURLs)
        let shouldUseTURN = !turnUsername.isEmpty && !turnPassword.isEmpty && !turnURIs.isEmpty
        guard shouldUseTURN else {
            throw CrossNetworkTURNCredentialService.CredentialError.invalidCredentials
        }

        return WebRTCSession.ICEConfig(
            stunURL: stunURL,
            turnURLs: turnURIs,
            turnUsername: turnUsername,
            turnPassword: turnPassword
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
    private struct CachedEntry: Sendable {
        let credentials: TURNCredentials
        let accessSequence: UInt64
    }

    fileprivate enum CredentialError: LocalizedError {
        case missingAdmissionLease
        case consumedAdmissionLeaseExpired
        case invalidCredentials
        case invalidResponse
        case serverRejected(statusCode: Int, responseBytes: Int)

        var errorDescription: String? {
            switch self {
            case .missingAdmissionLease:
                return "TURN admission lease is required."
            case .consumedAdmissionLeaseExpired:
                return "TURN admission lease has already been consumed and its credentials expired."
            case .invalidCredentials:
                return "TURN credential response does not contain usable URIs and credentials."
            case .invalidResponse:
                return "TURN credential response is invalid, expired, or oversized."
            case .serverRejected(let statusCode, let responseBytes):
                return "TURN credential server returned HTTP \(statusCode) (\(responseBytes) response bytes)."
            }
        }
    }

    private var cachedByTokenKey: [String: CachedEntry] = [:]
    private var accessSequence: UInt64 = 0
    private let maximumCachedEntries = 64
    private let minimumRefreshBuffer: TimeInterval = 10
    private let minimumUsableLifetime: TimeInterval = 10
    private let maximumResponseBytes = 64 * 1024

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

    func getCredentials(turnAdmissionToken: String?) async throws -> TURNCredentials {
        let normalizedToken = normalizedTurnAdmissionToken(turnAdmissionToken)
        if normalizedToken == nil {
            guard CrossNetworkServerConfig.allowStaticTurnFallback else {
                throw CredentialError.missingAdmissionLease
            }
            let staticCredentials = fallback(allowStaticTURN: true)
            guard Self.hasUsableCredentials(staticCredentials) else {
                throw CredentialError.invalidCredentials
            }
            logger.warning("⚠️ TURN admission lease missing; using explicitly enabled validated static TURN configuration.")
            return staticCredentials
        }
        let tokenKey = cacheKey(for: normalizedToken)
        if let cached = cachedCredentials(forKey: tokenKey) {
            if cached.isValid(buffer: refreshBuffer(for: cached)) {
                return cached
            }
            if normalizedToken != nil {
                logger.info("ℹ️ TURN admission token is single-use; reusing cached credentials until expiry.")
                if cached.isValid(buffer: 0) {
                    return cached
                }
                throw CredentialError.consumedAdmissionLeaseExpired
            }
        }
        do {
            let fresh = try await fetchFromServer(turnAdmissionToken: normalizedToken)
            store(fresh, forKey: tokenKey)
            return fresh
        } catch {
            if let cached = cachedCredentials(forKey: tokenKey),
               cached.isValid(buffer: 0) {
                logger.info("ℹ️ TURN credentials fetch failed; reusing cached credentials. err=\(error.localizedDescription, privacy: .public)")
                return cached
            }
            logger.error("❌ TURN credentials fetch failed and no valid cache exists: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    private func normalizedTurnAdmissionToken(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func cacheKey(for turnAdmissionToken: String?) -> String {
        guard let turnAdmissionToken else { return "__anonymous__" }
        let digest = SHA256.hash(data: Data(turnAdmissionToken.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func cachedCredentials(forKey key: String) -> TURNCredentials? {
        guard let entry = cachedByTokenKey[key] else { return nil }
        accessSequence &+= 1
        cachedByTokenKey[key] = CachedEntry(
            credentials: entry.credentials,
            accessSequence: accessSequence
        )
        return entry.credentials
    }

    private func store(_ credentials: TURNCredentials, forKey key: String) {
        if cachedByTokenKey[key] == nil,
           cachedByTokenKey.count >= maximumCachedEntries,
           let evictionKey = cachedByTokenKey.min(by: {
               $0.value.accessSequence < $1.value.accessSequence
           })?.key {
            cachedByTokenKey.removeValue(forKey: evictionKey)
        }
        accessSequence &+= 1
        cachedByTokenKey[key] = CachedEntry(
            credentials: credentials,
            accessSequence: accessSequence
        )
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

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        var data = Data()
        data.reserveCapacity(min(maximumResponseBytes, 4_096))
        for try await byte in bytes {
            guard data.count < maximumResponseBytes else {
                throw CredentialError.invalidResponse
            }
            data.append(byte)
        }
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let metadataHeaderCount = [
            "X-SkyBridge-Instance",
            "X-SkyBridge-State-Backend",
            "X-SkyBridge-Code-Prefixes"
        ].reduce(into: 0) { count, name in
            if http.value(forHTTPHeaderField: name) != nil { count += 1 }
        }
        logger.info("🌐 TURN credential response status=\(http.statusCode) metadataHeaders=\(metadataHeaderCount)")
        guard (200...299).contains(http.statusCode) else {
            throw CredentialError.serverRejected(
                statusCode: http.statusCode,
                responseBytes: data.count
            )
        }
        let decoded = try JSONDecoder().decode(ServerResponse.self, from: data)
        guard decoded.ttl > 0 else {
            throw CredentialError.invalidResponse
        }
        let ttl = decoded.ttl
        let now = Date()
        let ttlExpiresAt = now.addingTimeInterval(TimeInterval(ttl))
        let serverExpiresAt: Date
        if let expiresAtEpoch = decoded.expiresAt, expiresAtEpoch > 0 {
            serverExpiresAt = Date(timeIntervalSince1970: TimeInterval(expiresAtEpoch))
        } else {
            serverExpiresAt = ttlExpiresAt
        }
        let expiresAt = min(serverExpiresAt, ttlExpiresAt)
        guard expiresAt.timeIntervalSince(now) >= minimumUsableLifetime else {
            throw CredentialError.invalidResponse
        }
        let uris = CrossNetworkServerConfig.preferredTurnURIs(
            from: decoded.uris ?? [],
            fallback: CrossNetworkServerConfig.turnURLs
        )
        let credentials = TURNCredentials(
            username: decoded.username,
            password: decoded.password,
            ttl: ttl,
            uris: uris,
            expiresAt: expiresAt
        )
        guard Self.hasUsableCredentials(credentials) else {
            throw CredentialError.invalidCredentials
        }
        return credentials
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

    nonisolated private static func hasUsableCredentials(_ credentials: TURNCredentials) -> Bool {
        credentials.isValid(buffer: 0)
            && !credentials.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !credentials.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !CrossNetworkServerConfig.normalizedTurnURIs(credentials.uris).isEmpty
    }
}
