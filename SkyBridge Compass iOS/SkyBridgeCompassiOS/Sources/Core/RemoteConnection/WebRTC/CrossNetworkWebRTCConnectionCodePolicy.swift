import Foundation

@available(iOS 17.0, *)
extension CrossNetworkWebRTCManager {
    enum ConnectionCodeError: LocalizedError {
        case invalid

        var errorDescription: String? {
            switch self {
            case .invalid:
                return "连接码无效（需要 8 位，兼容 6 位旧码）"
            }
        }
    }

    private static let shortCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    private static let shortCodeAllowedCharacters = Set(shortCodeAlphabet)

    public static let legacyConnectionCodeLength = 6
    public static let preferredConnectionCodeLength = 8
    public static let maximumConnectionCodeLength = 16
    nonisolated static let connectionCodeMinimumReusableTime: TimeInterval = 15

    public static func sanitizeConnectionCodeInput(_ raw: String) -> String {
        String(
            raw
                .uppercased()
                .filter { shortCodeAllowedCharacters.contains($0) }
                .prefix(maximumConnectionCodeLength)
        )
    }

    public static func isSupportedConnectionCodeLength(_ count: Int) -> Bool {
        count == legacyConnectionCodeLength || (preferredConnectionCodeLength...maximumConnectionCodeLength).contains(count)
    }

    public static func canSubmitConnectionCode(_ raw: String) -> Bool {
        isSupportedConnectionCodeLength(sanitizeConnectionCodeInput(raw).count)
    }

    nonisolated static func isReusableConnectionCodeLease(
        expiresAt: Date?,
        now: Date = Date(),
        minimumRemainingTime: TimeInterval = connectionCodeMinimumReusableTime
    ) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) > minimumRemainingTime
    }

    func normalizeConnectionCode(_ raw: String) throws -> String {
        let code = Self.sanitizeConnectionCodeInput(raw)
        guard Self.isSupportedConnectionCodeLength(code.count) else { throw ConnectionCodeError.invalid }
        return code
    }

    static func generateShortCode() -> String {
        String((0..<preferredConnectionCodeLength).compactMap { _ in shortCodeAlphabet.randomElement() })
    }

    public static func isConnectLinkString(_ raw: String) -> Bool {
        CrossNetworkConnectPayloadParserCompat.extractPayload(from: raw.trimmingCharacters(in: .whitespacesAndNewlines)) != nil
    }

    nonisolated static func decodeConnectPayload(_ rawPayload: String) -> Data? {
        CrossNetworkConnectPayloadCodec.decodeBase64Payload(rawPayload)
    }
}
