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
private enum QPeriaptIOSPlatformPolicy {
    static func isPeerAppPlatformEligible(platform: String?, osVersion: String?) -> Bool {
        switch parse(platform: platform, osVersion: osVersion) {
        case .apple(let major):
            return major.map { $0 >= 26 } ?? false
        case .android(let releaseMajor, let api):
            return releaseMajor.map { $0 >= 16 } == true && api.map { $0 >= 36 } == true
        case .unsupported:
            return false
        }
    }

    private static func parse(platform: String?, osVersion: String?) -> PeerPlatformVersion {
        let platformValue = platform?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let platformValue, !platformValue.isEmpty else {
            return .unsupported
        }
        let versionValue = osVersion?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [platformValue, versionValue?.lowercased()]
            .compactMap { value -> String? in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " ")
        guard !combined.isEmpty else { return .unsupported }

        if combined.contains("android") || combined.contains("api ") {
            return .android(
                releaseMajor: firstMatch(in: combined, pattern: #"\bandroid\s+(\d{1,3})\b"#),
                api: firstMatch(in: combined, pattern: #"\bapi\s*(\d{1,3})\b"#)
            )
        }

        if combined.contains("macos") ||
            combined.contains("mac os") ||
            combined.range(of: #"\bios\b"#, options: .regularExpression) != nil {
            return .apple(major: firstMatch(in: versionValue ?? combined, pattern: #"\d{1,3}"#))
        }

        return .unsupported
    }

    private static func firstMatch(in value: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range) else { return nil }
        let captureRange = match.numberOfRanges > 1 ? match.range(at: 1) : match.range(at: 0)
        guard captureRange.location != NSNotFound,
              let valueRange = Range(captureRange, in: value)
        else { return nil }
        return Int(value[valueRange])
    }

    private enum PeerPlatformVersion {
        case apple(major: Int?)
        case android(releaseMajor: Int?, api: Int?)
        case unsupported
    }
}
