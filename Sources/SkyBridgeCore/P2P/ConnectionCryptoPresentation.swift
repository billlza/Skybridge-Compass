import Foundation

public enum ConnectionCryptoPresentation {
    public static func modeLabel(
        kind: String?,
        suite: String?,
        capability _: CryptoProviderFactory.Capability? = nil
    ) -> String? {
        let suiteToken = normalizedToken(suite)
        if suiteToken.contains("xwing") {
            return "X-Wing"
        }
        if suiteToken.contains("x25519") || suiteToken.contains("p256") {
            return "Classic"
        }

        let kindToken = normalizedToken(kind)
        if kindToken.contains("xwing") {
            return "X-Wing"
        }
        if kindToken.contains("liboqs") || kindToken.contains("oqs") {
            return "liboqs"
        }
        if kindToken.contains("apple"),
           suiteToken.contains("mlkem") || suiteToken.contains("mldsa") || suiteToken.contains("xwing") {
            return "Apple PQC"
        }
        if kindToken.contains("classic") {
            return "Classic"
        }

        if suiteToken.contains("mlkem") || suiteToken.contains("mldsa") {
            return "PQC"
        }

        return nil
    }

    public static func connectedStatusText(
        kind: String?,
        suite: String?,
        baseConnectedText: String
    ) -> String {
        guard let mode = modeLabel(kind: kind, suite: suite) else {
            return baseConnectedText
        }
        return "\(mode)\(baseConnectedText)"
    }

    public static func inferredModeLabelForCurrentPolicy(
        compatibilityModeEnabled _: Bool = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
    ) -> String? {
        nil
    }

    public static func connectedStatusTextWithPolicyFallback(
        kind: String?,
        suite: String?,
        baseConnectedText: String,
        compatibilityModeEnabled _: Bool = UserDefaults.standard.bool(forKey: "Settings.EnableCompatibilityMode")
    ) -> String {
        let explicit = connectedStatusText(
            kind: kind,
            suite: suite,
            baseConnectedText: baseConnectedText
        )
        if explicit != baseConnectedText {
            return explicit
        }

        return baseConnectedText
    }

    public static func detailText(
        kind: String?,
        suite: String?,
        guardStatus: String?
    ) -> String? {
        let mode = modeLabel(kind: kind, suite: suite)
        let trimmedSuite = trimmedValue(suite)
        let trimmedGuard = trimmedValue(guardStatus)

        var components: [String] = []
        if let mode {
            components.append(mode)
        }
        if let trimmedSuite, !shouldSuppressSuite(mode: mode, suite: trimmedSuite) {
            components.append(trimmedSuite)
        }
        if let trimmedGuard {
            components.append(trimmedGuard)
        }

        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private static func shouldSuppressSuite(mode: String?, suite: String) -> Bool {
        guard let mode else { return false }

        let modeToken = normalizedToken(mode)
        let suiteToken = normalizedToken(suite)

        if modeToken == suiteToken {
            return true
        }
        if modeToken == "xwing" && suiteToken.contains("xwing") {
            return true
        }

        return false
    }

    private static func trimmedValue(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedToken(_ value: String?) -> String {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return ""
        }

        var token = String()
        token.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            token.unicodeScalars.append(scalar)
        }
        return token
    }
}
