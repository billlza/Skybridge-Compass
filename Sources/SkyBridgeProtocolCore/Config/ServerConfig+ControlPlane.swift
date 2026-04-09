import Foundation

extension SkyBridgeServerConfig {
    private static func normalizedValue(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func booleanValue(
        for key: String,
        environment: [String: String],
        infoDictionary: [String: Any]?
    ) -> Bool? {
        func parse(_ raw: String) -> Bool? {
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                return nil
            }
        }

        if let raw = environment[key], let parsed = parse(raw) {
            return parsed
        }

        if let raw = infoDictionary?[key] as? String, let parsed = parse(raw) {
            return parsed
        }

        if let raw = infoDictionary?[key] as? NSNumber {
            return raw.boolValue
        }

        return nil
    }

    public static func normalizedTurnURIs(_ uris: [String]) -> [String] {
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

    private static func turnPriority(_ uri: String) -> Int {
        let lower = uri.lowercased()
        if lower.hasPrefix("turns:") { return 0 }
        if lower.contains("transport=tcp") { return 1 }
        return 2
    }

    public static func preferredTurnURIs(from uris: [String], fallback: [String]) -> [String] {
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

    /// Client API key used by control-plane requests.
    /// Deployments must inject it explicitly; no repository default is provided.
    public static var clientAPIKey: String {
        if let key = ProcessInfo.processInfo.environment["SKYBRIDGE_CLIENT_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !key.isEmpty {
            return key
        }
        if let key = Bundle.main.object(forInfoDictionaryKey: "SKYBRIDGE_CLIENT_API_KEY") as? String {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return "skybridge-client-v1"
    }

    public static func staticTURNFallbackAllowed(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Bool {
        booleanValue(
            for: "SKYBRIDGE_ALLOW_STATIC_TURN_FALLBACK",
            environment: environment,
            infoDictionary: infoDictionary
        ) ?? false
    }

    public static var allowStaticTURNFallback: Bool {
        staticTURNFallbackAllowed()
    }
}
