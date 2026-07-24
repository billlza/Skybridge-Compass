import Foundation

/// KEM identity public key info (suite wire id + raw public key bytes).
/// Keep this wire-compatible with macOS SkyBridgeCore `KEMPublicKeyInfo`.
@available(iOS 17.0, *)
public struct KEMPublicKeyInfo: Codable, Sendable, Equatable {
    public let suiteWireId: UInt16
    public let publicKey: Data

    public init(suiteWireId: UInt16, publicKey: Data) {
        self.suiteWireId = suiteWireId
        self.publicKey = publicKey
    }

    public static func normalizedValidKeys(_ rawKeys: [KEMPublicKeyInfo]) -> [KEMPublicKeyInfo] {
        normalizedValidKeys(rawKeys, platform: nil, osVersion: nil, requireQPeriaptPeerPlatform: false)
    }

    public static func normalizedValidKeys(
        _ rawKeys: [KEMPublicKeyInfo],
        platform: String?,
        osVersion: String?
    ) -> [KEMPublicKeyInfo] {
        normalizedValidKeys(
            rawKeys,
            platform: platform,
            osVersion: osVersion,
            requireQPeriaptPeerPlatform: true
        )
    }

    private static func normalizedValidKeys(
        _ rawKeys: [KEMPublicKeyInfo],
        platform: String?,
        osVersion: String?,
        requireQPeriaptPeerPlatform: Bool
    ) -> [KEMPublicKeyInfo] {
        var bySuite: [UInt16: KEMPublicKeyInfo] = [:]
        for key in rawKeys where key.hasValidStrictPQCMaterial(
            platform: platform,
            osVersion: osVersion,
            requireQPeriaptPeerPlatform: requireQPeriaptPeerPlatform
        ) {
            bySuite[key.suiteWireId] = key
        }
        return bySuite.keys.sorted().compactMap { bySuite[$0] }
    }

    private func hasValidStrictPQCMaterial(
        platform: String?,
        osVersion: String?,
        requireQPeriaptPeerPlatform: Bool
    ) -> Bool {
        let suite = CryptoSuite(wireId: suiteWireId)
        guard suite.isNegotiable, suite.isPQCGroup else { return false }
        if suite.canonicalKEMSuite.wireId == CryptoSuite.qperiaptABI2PolicyBound.wireId,
           requireQPeriaptPeerPlatform,
           !QPeriaptIOSPlatformPolicy.isPeerAppPlatformEligible(platform: platform, osVersion: osVersion) {
            return false
        }
        return publicKey.count == Self.expectedPublicKeyLength(for: suite)
    }

    private static func expectedPublicKeyLength(for suite: CryptoSuite) -> Int {
        switch suite.canonicalKEMSuite.wireId {
        case CryptoSuite.xwing.wireId: return 1_216
        case CryptoSuite.qperiaptABI2PolicyBound.wireId: return 1_216
        case CryptoSuite.mlkem768.wireId,
             CryptoSuite.mlkem768fs.wireId: return 1_184
        default: return 0
        }
    }
}

@available(iOS 17.0, *)
enum QPeriaptIOSPlatformPolicy {
    static func isPeerAppPlatformEligible(platform: String?, osVersion: String?) -> Bool {
        guard let platform = platform?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              let osVersion = osVersion?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !platform.isEmpty,
              !osVersion.isEmpty else {
            return false
        }

        let expectedFamily: PeerPlatformFamily
        switch platform {
        case "ios": expectedFamily = .iOS
        case "macos", "mac os": expectedFamily = .macOS
        case "android": expectedFamily = .android
        default: return false
        }

        let fullVersion: String
        if Self.matches(osVersion, pattern: #"^\d{1,3}(?:\.\d{1,3}){0,2}$"#) {
            guard expectedFamily != .android else { return false }
            fullVersion = "\(expectedFamily.capabilityName) \(osVersion)"
        } else {
            fullVersion = osVersion
        }

        guard let parsed = parseFullPlatformVersion(fullVersion),
              parsed.family == expectedFamily else {
            return false
        }
        return parsed.isEligible
    }

    static func isPeerHandshakePlatformVersionEligible(_ platformVersion: String) -> Bool {
        guard let parsed = parseFullPlatformVersion(platformVersion) else { return false }
        return parsed.isEligible
    }

    private static func parseFullPlatformVersion(
        _ value: String
    ) -> ParsedPeerPlatformVersion? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let match = firstMatch(
            in: trimmed,
            pattern: #"(?i)^(ios|macos|mac\s+os)\s+(\d{1,3})(?:\.\d{1,3}){0,2}$"#
        ), let familyName = capturedString(in: trimmed, match: match, capture: 1)?
            .lowercased(),
           let major = capturedInteger(in: trimmed, match: match, capture: 2) {
            let family: PeerPlatformFamily = familyName == "ios" ? .iOS : .macOS
            return ParsedPeerPlatformVersion(family: family, major: major, api: nil)
        }

        if let match = firstMatch(
            in: trimmed,
            pattern: #"(?i)^android\s+(\d{1,3})(?:\.\d{1,3}){0,2}\s*(?:\(\s*api\s*(\d{1,3})\s*\)|api\s*(\d{1,3}))$"#
        ), let releaseMajor = capturedInteger(in: trimmed, match: match, capture: 1),
           let api = capturedInteger(in: trimmed, match: match, capture: 2)
            ?? capturedInteger(in: trimmed, match: match, capture: 3) {
            return ParsedPeerPlatformVersion(
                family: .android,
                major: releaseMajor,
                api: api
            )
        }

        return nil
    }

    private static func matches(_ value: String, pattern: String) -> Bool {
        firstMatch(in: value, pattern: pattern) != nil
    }

    private static func firstMatch(
        in value: String,
        pattern: String
    ) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.firstMatch(in: value, range: range)
    }

    private static func capturedInteger(
        in value: String,
        match: NSTextCheckingResult,
        capture: Int
    ) -> Int? {
        capturedString(in: value, match: match, capture: capture).flatMap(Int.init)
    }

    private static func capturedString(
        in value: String,
        match: NSTextCheckingResult,
        capture: Int
    ) -> String? {
        guard capture < match.numberOfRanges else { return nil }
        let captureRange = match.range(at: capture)
        guard captureRange.location != NSNotFound,
              let valueRange = Range(captureRange, in: value) else {
            return nil
        }
        return String(value[valueRange])
    }

    private enum PeerPlatformFamily: Equatable {
        case iOS
        case macOS
        case android

        var capabilityName: String {
            switch self {
            case .iOS: return "iOS"
            case .macOS: return "macOS"
            case .android: return "Android"
            }
        }
    }

    private struct ParsedPeerPlatformVersion {
        let family: PeerPlatformFamily
        let major: Int
        let api: Int?

        var isEligible: Bool {
            switch family {
            case .iOS, .macOS:
                return major >= 26
            case .android:
                return major >= 16 && api.map { $0 >= 36 } == true
            }
        }
    }
}
