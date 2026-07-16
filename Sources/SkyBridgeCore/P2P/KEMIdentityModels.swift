//
// KEMIdentityModels.swift
// SkyBridgeCore
//
// KEM identity public key models for trust and certificates.
//

import Foundation

/// Canonical fixed-length contract for persisted or benchmark-scoped KEM identities.
///
/// Keeping this table beside KEM identity wire models prevents storage adapters
/// from drifting on provider-specific private-key encodings while sharing the
/// same public wire suite.
public struct KEMIdentityKeyLengthContract: Sendable, Equatable {
    public let publicKeyLength: Int
    public let privateKeyLength: Int

    init(publicKeyLength: Int, privateKeyLength: Int) {
        precondition(publicKeyLength > 0, "KEM public-key length must be positive")
        precondition(privateKeyLength > 0, "KEM private-key length must be positive")
        self.publicKeyLength = publicKeyLength
        self.privateKeyLength = privateKeyLength
    }

    public static func resolve(
        suite: CryptoSuite,
        providerTier: CryptoTier
    ) -> Self? {
        let canonicalSuite = suite.canonicalKEMSuite
        switch (canonicalSuite.wireId, providerTier) {
        case (0x0012, .qperiaptPQC):
            return Self(
                publicKeyLength: QPeriaptPlatformPolicy.publicKeyLength,
                privateKeyLength: QPeriaptPlatformPolicy.privateKeyLength
            )
        case (0x0101, .nativePQC):
            return Self(publicKeyLength: 1_184, privateKeyLength: 96)
        case (0x0101, .liboqsPQC):
            return Self(publicKeyLength: 1_184, privateKeyLength: 2_400)
        case (0x0001, .nativePQC):
            return Self(publicKeyLength: 1_216, privateKeyLength: 64)
        default:
            return nil
        }
    }

    public static func publicKeyLength(suite: CryptoSuite) -> Int? {
        let canonicalSuite = suite.canonicalKEMSuite
        switch canonicalSuite.wireId {
        case 0x0012: return QPeriaptPlatformPolicy.publicKeyLength
        case 0x0101: return 1_184
        case 0x0001: return 1_216
        default: return nil
        }
    }
}

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
        guard suite.isNegotiable, suite.isPQCGroup else { return false }
        if suite.canonicalKEMSuite.wireId == CryptoSuite.qperiaptABI2PolicyBound.wireId,
           requireQPeriaptPeerPlatform,
           !QPeriaptPlatformPolicy.isPeerAppPlatformEligible(platform: platform, osVersion: osVersion) {
            return false
        }
        guard let expectedLength = KEMIdentityKeyLengthContract.publicKeyLength(
            suite: suite
        ) else {
            return false
        }
        return publicKey.count == expectedLength
    }
}
