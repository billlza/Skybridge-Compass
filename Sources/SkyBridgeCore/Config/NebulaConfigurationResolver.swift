import Foundation

/// Resolves Nebula client configuration from the same key names across app targets.
///
/// Resolution order is per-key:
/// 1. Keychain
/// 2. Process environment
/// 3. App Info.plist
/// 4. Optional `NebulaConfig.plist` in the app bundle or SwiftPM resource bundle
///
/// This lets us keep public defaults in Info.plist while storing user overrides
/// and optional compatibility secrets outside the application bundle.
public enum NebulaConfigurationResolver {
    public static let requiredKeys = [
        "NEBULA_BASE_URL",
        "NEBULA_CLIENT_ID"
    ]
    public static let optionalKeys = [
        "NEBULA_CLIENT_SECRET"
    ]

    public struct ResolvedConfiguration: Sendable, Equatable {
        public let baseURL: String
        public let clientId: String
        public let clientSecret: String?
        public let sourceDescription: String
    }

    public static func resolve(bundle: Bundle = .main) -> ResolvedConfiguration? {
        var sources: [String] = []

        guard let baseURL = resolvedValue(
            forKey: "NEBULA_BASE_URL",
            bundle: bundle,
            sources: &sources,
            validator: isValidBaseURL
        ),
        let clientId = resolvedValue(
            forKey: "NEBULA_CLIENT_ID",
            bundle: bundle,
            sources: &sources
        ) else {
            return nil
        }

        let clientSecret = resolvedValue(
            forKey: "NEBULA_CLIENT_SECRET",
            bundle: bundle,
            sources: &sources
        )

        return ResolvedConfiguration(
            baseURL: baseURL,
            clientId: clientId,
            clientSecret: clientSecret,
            sourceDescription: sources.joined(separator: " + ")
        )
    }

    public static var requiredKeysDescription: String {
        requiredKeys.joined(separator: " / ")
    }

    public static var optionalKeysDescription: String {
        optionalKeys.joined(separator: " / ")
    }

    private static func resolvedValue(
        forKey key: String,
        bundle: Bundle,
        sources: inout [String],
        validator: (String) -> Bool = { !$0.isEmpty }
    ) -> String? {
        if let value = normalizedKeychainValue(forKey: key),
           !isPlaceholder(value, forKey: key),
           validator(value) {
            appendSource("Keychain", to: &sources)
            return value
        }

        if let value = normalizedEnvironmentValue(forKey: key),
           !isPlaceholder(value, forKey: key),
           validator(value) {
            appendSource("Environment", to: &sources)
            return value
        }

        if let value = normalizedInfoValue(forKey: key, bundle: bundle),
           !isPlaceholder(value, forKey: key),
           validator(value) {
            appendSource("Info.plist", to: &sources)
            return value
        }

        if let value = normalizedResourceValue(forKey: key, bundle: bundle),
           !isPlaceholder(value, forKey: key),
           validator(value) {
            appendSource("NebulaConfig.plist", to: &sources)
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

    private static func normalizedEnvironmentValue(forKey key: String) -> String? {
        normalized(ProcessInfo.processInfo.environment[key])
    }

    private static func normalizedInfoValue(forKey key: String, bundle: Bundle) -> String? {
        normalized(bundle.object(forInfoDictionaryKey: key) as? String)
    }

    private static func normalizedResourceValue(forKey key: String, bundle: Bundle) -> String? {
        if let value = plistValue(forKey: key, bundle: bundle) {
            return value
        }

#if SWIFT_PACKAGE
        if bundle != Bundle.module, let value = plistValue(forKey: key, bundle: Bundle.module) {
            return value
        }
#endif

        return nil
    }

    private static func plistValue(forKey key: String, bundle: Bundle) -> String? {
        guard let url = bundle.url(forResource: "NebulaConfig", withExtension: "plist"),
              let dict = NSDictionary(contentsOf: url) as? [String: Any] else {
            return nil
        }
        return normalized(dict[key] as? String)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func isValidBaseURL(_ value: String) -> Bool {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host,
              !host.isEmpty else {
            return false
        }
        return true
    }

    private static func isPlaceholder(_ value: String, forKey key: String) -> Bool {
        let lowered = value.lowercased()
        switch key {
        case "NEBULA_BASE_URL":
            return lowered.contains("your-nebula-host")
                || lowered.contains("example.com")
        case "NEBULA_CLIENT_ID":
            return lowered == "your-nebula-client-id"
        case "NEBULA_CLIENT_SECRET":
            return lowered == "your-nebula-client-secret"
        default:
            return false
        }
    }

    private static func appendSource(_ source: String, to sources: inout [String]) {
        if !sources.contains(source) {
            sources.append(source)
        }
    }
}
