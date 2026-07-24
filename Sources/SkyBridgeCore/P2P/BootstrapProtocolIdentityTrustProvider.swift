import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct BootstrapProtocolIdentityTrustProvider: MultiFingerprintHandshakeTrustProvider, ExactProtocolIdentityHandshakeTrustProvider, Sendable {
    private let protocolIdentityFingerprint: String
    private let exactProtocolIdentity: TrustedProtocolIdentityRawKey?

    init?(
        protocolIdentityFingerprint: String,
        protocolSigningAlgorithm: ProtocolSigningAlgorithm? = nil,
        protocolPublicKey: Data? = nil
    ) {
        let normalized = protocolIdentityFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else {
            return nil
        }
        switch (protocolSigningAlgorithm, protocolPublicKey) {
        case (nil, nil):
            exactProtocolIdentity = nil
        case (.some(let algorithm), .some(let publicKey)):
            let identity = IdentityPublicKeys(
                protocolPublicKey: publicKey,
                protocolAlgorithm: algorithm.wire
            )
            guard (try? identity.authoritativeProtocolFingerprint().lowercased()) == normalized else {
                return nil
            }
            exactProtocolIdentity = TrustedProtocolIdentityRawKey(
                algorithm: algorithm,
                publicKey: publicKey
            )
        default:
            return nil
        }
        self.protocolIdentityFingerprint = normalized
    }

    func trustedFingerprint(for deviceId: String) async -> String? {
        _ = deviceId
        return protocolIdentityFingerprint
    }

    func trustedFingerprints(for deviceId: String) async -> Set<String> {
        _ = deviceId
        return [protocolIdentityFingerprint]
    }

    func trustedProtocolIdentityRawKeys(for deviceId: String) async -> [TrustedProtocolIdentityRawKey] {
        _ = deviceId
        return exactProtocolIdentity.map { [$0] } ?? []
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        _ = deviceId
        return [:]
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        _ = deviceId
        return nil
    }

    func requiresPinnedProtocolIdentity(for deviceId: String) async -> Bool {
        _ = deviceId
        return true
    }
}
