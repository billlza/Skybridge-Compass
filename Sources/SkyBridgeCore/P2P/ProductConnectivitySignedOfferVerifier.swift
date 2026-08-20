import Foundation
import SkyBridgeProtocolCore

/// Verifies the protocol signature on a classic-only MessageA before a strict
/// product endpoint emits policy-rejection evidence.
///
/// Structural decoding alone is intentionally insufficient: an unauthenticated
/// packet can still be rejected by policy, but it cannot become release proof.
@available(macOS 14.0, iOS 17.0, *)
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
