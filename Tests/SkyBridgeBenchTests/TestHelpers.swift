import Foundation
@testable import SkyBridgeCore

func encodeIdentityPublicKey(
    _ publicKey: Data,
    algorithm: SignatureAlgorithm = .ed25519,
    secureEnclavePublicKey: Data? = nil
) -> Data {
    IdentityPublicKeys(
        protocolPublicKey: publicKey,
        protocolAlgorithm: algorithm,
        secureEnclavePublicKey: secureEnclavePublicKey
    ).encoded
}
