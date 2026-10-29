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

    nonisolated private static let shortCodeAlphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    nonisolated private static let shortCodeAllowedCharacters = Set(shortCodeAlphabet)

    public nonisolated static let legacyConnectionCodeLength = 6
    public nonisolated static let preferredConnectionCodeLength = 8
    public nonisolated static let maximumConnectionCodeLength = 16
    nonisolated static let connectionCodeMinimumReusableTime: TimeInterval = 15

    public nonisolated static func sanitizeConnectionCodeInput(_ raw: String) -> String {
        String(
            raw
                .uppercased()
                .filter { shortCodeAllowedCharacters.contains($0) }
                .prefix(maximumConnectionCodeLength)
        )
    }

    public nonisolated static func isSupportedConnectionCodeLength(_ count: Int) -> Bool {
        count == legacyConnectionCodeLength || (preferredConnectionCodeLength...maximumConnectionCodeLength).contains(count)
    }

    public nonisolated static func canSubmitConnectionCode(_ raw: String) -> Bool {
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

    /// Short connection-code QR scheme: `skybridge://code/<code>`.
    ///
    /// This carries ONLY the server-issued short lease code (see `generateConnectionCode()` →
    /// `registerConnectionCode`). The scanning peer redeems it through the signaling server via
    /// `connect(withCode:)`, which recovers the initiator's origin/token/protocol-identity authority
    /// from the server `lookupConnectionCode` response and enforces the current-path trust binding.
    /// No PQC key material is embedded in the QR, so the payload stays at QR Version 1-2 (scannable),
    /// while the cross-network trust guarantees are identical to the legacy `skybridge://connect/...`
    /// self-contained QR (both are server-backed; neither imports KEM trust from the QR itself).
    ///
    /// Returns the normalized, length-validated connection code, or `nil` if `raw` is not a
    /// well-formed short-code link with a valid code.
    public static func extractConnectionCode(fromScannedString raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let codeToken: String
        let prefix = "skybridge://code/"
        if trimmed.hasPrefix(prefix) {
            codeToken = String(trimmed.dropFirst(prefix.count))
        } else if let url = URL(string: trimmed),
                  url.scheme == "skybridge",
                  url.host == "code" {
            codeToken = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        } else {
            return nil
        }
        let sanitized = sanitizeConnectionCodeInput(codeToken)
        guard !sanitized.isEmpty, isSupportedConnectionCodeLength(sanitized.count) else { return nil }
        return sanitized
    }

    /// Render form for the short connection-code QR. Kept alongside the parser so the generate and
    /// scan sides cannot drift out of sync.
    public static func connectionCodeLink(for code: String) -> String {
        "skybridge://code/\(code)"
    }

    nonisolated static func decodeConnectPayload(_ rawPayload: String) -> Data? {
        CrossNetworkConnectPayloadCodec.decodeBase64Payload(rawPayload)
    }
}
