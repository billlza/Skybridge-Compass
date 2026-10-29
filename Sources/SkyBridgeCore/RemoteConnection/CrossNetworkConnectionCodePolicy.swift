import Foundation

public enum CrossNetworkConnectionCodePolicy {
    private static let shortCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let shortCodeAllowedCharacters = Set(shortCodeAlphabet)

    public static let legacyConnectionCodeLength = 6
    public static let preferredConnectionCodeLength = 8
    public static let maximumConnectionCodeLength = 16

    public static func sanitize(_ raw: String) -> String {
        String(
            raw
                .uppercased()
                .filter { shortCodeAllowedCharacters.contains($0) }
                .prefix(maximumConnectionCodeLength)
        )
    }

    public static func isSupportedLength(_ count: Int) -> Bool {
        count == legacyConnectionCodeLength || (preferredConnectionCodeLength...maximumConnectionCodeLength).contains(count)
    }

    public static func canSubmit(_ raw: String) -> Bool {
        isSupportedLength(sanitize(raw).count)
    }

    static func normalize(_ raw: String) -> String? {
        let normalized = sanitize(raw)
        guard isSupportedLength(normalized.count) else { return nil }
        return normalized
    }
}

extension CrossNetworkConnectionManager {
    public nonisolated static let legacyConnectionCodeLength =
        CrossNetworkConnectionCodePolicy.legacyConnectionCodeLength
    public nonisolated static let preferredConnectionCodeLength =
        CrossNetworkConnectionCodePolicy.preferredConnectionCodeLength
    public nonisolated static let maximumConnectionCodeLength =
        CrossNetworkConnectionCodePolicy.maximumConnectionCodeLength
    nonisolated static let connectionCodeMinimumReusableTime: TimeInterval = 15

    public nonisolated static func sanitizeConnectionCodeInput(_ raw: String) -> String {
        CrossNetworkConnectionCodePolicy.sanitize(raw)
    }

    public nonisolated static func isSupportedConnectionCodeLength(_ count: Int) -> Bool {
        CrossNetworkConnectionCodePolicy.isSupportedLength(count)
    }

    public nonisolated static func canSubmitConnectionCode(_ raw: String) -> Bool {
        CrossNetworkConnectionCodePolicy.canSubmit(raw)
    }

    nonisolated static func isReusableConnectionCodeLease(
        expiresAt: Date?,
        now: Date = Date(),
        minimumRemainingTime: TimeInterval = connectionCodeMinimumReusableTime
    ) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) > minimumRemainingTime
    }

    nonisolated static func normalizeConnectionCode(_ raw: String) -> String? {
        CrossNetworkConnectionCodePolicy.normalize(raw)
    }
}
