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
}
