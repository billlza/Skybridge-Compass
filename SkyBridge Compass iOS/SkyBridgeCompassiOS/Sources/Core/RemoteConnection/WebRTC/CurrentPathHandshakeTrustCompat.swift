import Foundation

@available(iOS 17.0, *)
struct CurrentPathRemoteAuthorityCompat: Sendable, Equatable {
    let deviceId: String
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKeyFingerprint: String
    let protocolPublicKeyBytes: Data?
    let deviceName: String?
}

@available(iOS 17.0, *)
struct PendingVerifiedQRAuthorityCompat: Sendable, Equatable {
    let protocolPublicKeyFingerprint: String
    let verifiedAt: Date
}

@available(iOS 17.0, *)
enum CurrentPathRebindSource: Sendable, Equatable {
    case none
    case verifiedQRCode
    case verifiedConnectionCode
}

@available(iOS 17.0, *)
struct CurrentPathHandshakeTrustProviderCompat: MultiFingerprintHandshakeTrustProvider, Sendable {
    let expectedRemoteAuthority: CurrentPathRemoteAuthorityCompat?
    let fallbackPeerIDs: [String]
    let additionalTrustedFingerprints: Set<String>

    func trustedFingerprint(for deviceId: String) async -> String? {
        if let expectedRemoteAuthority,
           deviceId == expectedRemoteAuthority.deviceId || fallbackPeerIDs.contains(deviceId) {
            return expectedRemoteAuthority.protocolPublicKeyFingerprint
        }
        return nil
    }

    func trustedFingerprints(for deviceId: String) async -> Set<String> {
        guard let expected = await trustedFingerprint(for: deviceId) else {
            return []
        }
        var fingerprints = Set<String>()
        let normalizedExpected = expected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedExpected.isEmpty {
            fingerprints.insert(normalizedExpected)
        }
        for fingerprint in additionalTrustedFingerprints {
            let normalized = fingerprint.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty {
                fingerprints.insert(normalized)
            }
        }
        return fingerprints
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        let pinnedFingerprints = await trustedFingerprints(for: deviceId)
        guard !pinnedFingerprints.isEmpty else { return [:] }
        return await KEMTrustStore.shared.signedRefreshKEMPublicKeys(
            forAny: [deviceId] + fallbackPeerIDs,
            pinnedProtocolFingerprints: pinnedFingerprints
        )
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        nil
    }

    func requiresPinnedProtocolIdentity(for deviceId: String) async -> Bool {
        _ = deviceId
        return expectedRemoteAuthority != nil
    }
}
