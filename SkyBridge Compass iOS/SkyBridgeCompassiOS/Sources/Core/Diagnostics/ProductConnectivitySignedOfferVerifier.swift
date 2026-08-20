import Foundation
import SkyBridgeProtocolCore

/// iOS adapter for authenticating a classic-only MessageA before its strict
/// policy rejection is admitted as shipping-product evidence.
@available(iOS 17.0, *)
enum ProductConnectivitySignedOfferVerifier {
    static func isValidClassicOnlyOffer(_ messageA: HandshakeMessageA) async -> Bool {
        guard Set(messageA.supportedSuites.map(\.wireId)).count
                == messageA.supportedSuites.count,
              ProductConnectivityProfileClassifier.offeredProfiles(
                suiteWireIDs: messageA.supportedSuites.map(\.wireId)
              ) == .classic,
              let identity = try? messageA.decodedIdentityPublicKeys()
                .asProtocolIdentityKeys(),
              identity.protocolAlgorithm == .ed25519 else {
            return false
        }
        let verifier = ProtocolSignatureProviderSelector.select(for: .ed25519)
        return (try? await verifier.verify(
            messageA.signaturePreimage,
            signature: messageA.signature,
            publicKey: identity.protocolPublicKey
        )) == true
    }
}
