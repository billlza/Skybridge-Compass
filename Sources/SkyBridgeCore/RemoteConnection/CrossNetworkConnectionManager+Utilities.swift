import CryptoKit
import Foundation

@MainActor
extension CrossNetworkConnectionManager {
    nonisolated static func isAppleXWingRuntimeAvailableForWebRTCRekey() -> Bool {
        #if HAS_APPLE_PQC_SDK
        if #available(iOS 26.0, macOS 26.0, *) {
            return AppleXWingCryptoProvider.selfTest()
        }
        #endif
        return false
    }

    nonisolated static func webRTCPQCRekeyProviderCandidates(
        from plans: [WebRTCPQCHandshakePolicy.RekeyProviderPlan]
    ) -> [(provider: any CryptoProvider, label: String, suites: [CryptoSuite])] {
        plans.compactMap { plan in
            switch plan.label {
            case "native-xwing":
                #if HAS_APPLE_PQC_SDK
                if #available(iOS 26.0, macOS 26.0, *) {
                    return (AppleXWingCryptoProvider(), plan.label, plan.suites)
                }
                #endif
                return nil
            case "native-pqc":
                #if HAS_APPLE_PQC_SDK
                if #available(iOS 26.0, macOS 26.0, *) {
                    return (ApplePQCCryptoProvider(), plan.label, plan.suites)
                }
                #endif
                return nil
            case "liboqs", "liboqs-fallback":
                return (OQSPQCCryptoProvider(), plan.label, plan.suites)
            default:
                return nil
            }
        }
    }

    static func extractConnectPayload(from raw: String) -> String? {
        CrossNetworkConnectPayloadParser.extractPayload(from: raw)
    }

    nonisolated static var isAppleSiliconRuntime: Bool {
        #if arch(arm64) || arch(arm64e)
        true
        #else
        false
        #endif
    }

    nonisolated static func crossNetworkPresencePeerID(sessionID: String) -> String {
        "cross-network:\(sessionID)"
    }

    nonisolated static func deriveTenantIdentifier(accessToken: String?) -> String {
        CrossNetworkTenantIdentifierPolicy.derive(accessToken: accessToken)
    }

    private static func deriveSharedSecret(
        localPrivateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKey: Data
    ) throws -> SymmetricKey {
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let sharedSecret = try localPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        return sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data(),
            sharedInfo: Data(),
            outputByteCount: 32
        )
    }
}
