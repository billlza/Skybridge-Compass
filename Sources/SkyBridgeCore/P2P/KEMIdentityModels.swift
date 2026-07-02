//
// KEMIdentityModels.swift
// SkyBridgeCore
//
// KEM identity public key models for trust and certificates.
//

import Foundation

/// KEM 身份公钥信息
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
        guard suite.isKnown, suite.isPQCGroup else { return false }
        if suite.canonicalKEMSuite.wireId == CryptoSuite.qperiaptContextBound.wireId,
           requireQPeriaptPeerPlatform,
           !QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: platform, osVersion: osVersion) {
            return false
        }
        return publicKey.count == Self.expectedPublicKeyLength(for: suite)
    }

    private static func expectedPublicKeyLength(for suite: CryptoSuite) -> Int {
        switch suite.canonicalKEMSuite.wireId {
        case CryptoSuite.xwingMLDSA.wireId: return 1_216
        case CryptoSuite.qperiaptContextBound.wireId: return QPeriaptPlatformPolicy.publicKeyLength
        case CryptoSuite.mlkem768MLDSA65.wireId,
             CryptoSuite.mlkem768MLDSA65FS.wireId: return 1_184
        default: return 0
        }
    }
}
