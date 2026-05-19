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
        var bySuite: [UInt16: KEMPublicKeyInfo] = [:]
        for key in rawKeys where key.hasValidStrictPQCMaterial {
            bySuite[key.suiteWireId] = key
        }
        return bySuite.keys.sorted().compactMap { bySuite[$0] }
    }

    private var hasValidStrictPQCMaterial: Bool {
        let suite = CryptoSuite(wireId: suiteWireId)
        guard suite.isKnown, suite.isPQCGroup else { return false }
        return publicKey.count == Self.expectedPublicKeyLength(for: suite)
    }

    private static func expectedPublicKeyLength(for suite: CryptoSuite) -> Int {
        switch suite.canonicalKEMSuite.wireId {
        case CryptoSuite.xwingMLDSA.wireId: return 1_216
        case CryptoSuite.mlkem768MLDSA65.wireId,
             CryptoSuite.mlkem768MLDSA65FS.wireId: return 1_184
        default: return 0
        }
    }
}
