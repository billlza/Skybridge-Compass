import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct BootstrapProtocolIdentityTrustProvider: MultiFingerprintHandshakeTrustProvider, Sendable {
    private let protocolIdentityFingerprint: String

    init?(protocolIdentityFingerprint: String) {
        let normalized = protocolIdentityFingerprint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else {
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
