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
}


