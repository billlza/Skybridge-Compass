import Foundation
import SkyBridgeProtocolCore

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
        QPeriaptPeerPlatformPolicy.isPeerAppPlatformEligible(
            platform: platform,
            osVersion: osVersion
        )
    }

    static func isPeerHandshakePlatformVersionEligible(_ platformVersion: String) -> Bool {
        QPeriaptPeerPlatformPolicy.isPeerHandshakePlatformVersionEligible(platformVersion)
    }
}
