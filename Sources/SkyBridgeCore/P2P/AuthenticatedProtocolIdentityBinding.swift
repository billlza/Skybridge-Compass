import Foundation

/// Matches a post-authentication identity payload to the authority proved by
/// the handshake. The payload is never a trust source on its own: callers may
/// persist or auto-approve a key only when this exact binding succeeds.
@available(macOS 14.0, iOS 17.0, *)
enum AuthenticatedProtocolIdentityBinding {
    static func matchingPublicKey(
        in payload: AppMessage.PairingIdentityExchangePayload,
        authority: AuthenticatedRemoteAuthority
    ) -> Data? {
        let expectedAlgorithm = authority.protocolSigningAlgorithm.rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let expectedFingerprint = authority.protocolPublicKeyFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !expectedAlgorithm.isEmpty, !expectedFingerprint.isEmpty else {
            return nil
        }

        return (
            AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(
                payload.protocolIdentityPublicKeys
            ) ?? []
        ).first { key in
            key.protocolSigningAlgorithm
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() == expectedAlgorithm
                && (authority.protocolPublicKey == nil
                    || key.publicKey == authority.protocolPublicKey)
                && key.authoritativeFingerprint?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == expectedFingerprint
        }?.publicKey
    }
}
