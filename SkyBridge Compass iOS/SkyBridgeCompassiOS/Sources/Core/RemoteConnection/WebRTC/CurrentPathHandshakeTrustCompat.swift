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
    let exactMLDSA87PublicKey: Data?

    init(
        expectedRemoteAuthority: CurrentPathRemoteAuthorityCompat?,
        fallbackPeerIDs: [String],
        additionalTrustedFingerprints: Set<String>,
        exactMLDSA87PublicKey: Data? = nil
    ) {
        self.expectedRemoteAuthority = expectedRemoteAuthority
        self.fallbackPeerIDs = fallbackPeerIDs
        self.additionalTrustedFingerprints = additionalTrustedFingerprints
        self.exactMLDSA87PublicKey = exactMLDSA87PublicKey
            ?? (expectedRemoteAuthority?.protocolSigningAlgorithm == .mlDSA87
                ? expectedRemoteAuthority?.protocolPublicKeyBytes
                : nil)
    }

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

    func trustedProtocolIdentityPublicKey(
        for deviceId: String,
        algorithm: ProtocolSigningAlgorithm
    ) async -> Data? {
        guard algorithm == .mlDSA87,
              let expectedRemoteAuthority,
              deviceId == expectedRemoteAuthority.deviceId
                || fallbackPeerIDs.contains(deviceId) else {
            return nil
        }
        return exactMLDSA87PublicKey
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        let pinnedFingerprints = await trustedFingerprints(for: deviceId)
        guard !pinnedFingerprints.isEmpty else { return [:] }
        let signedRefresh = await KEMTrustStore.shared.signedRefreshKEMPublicKeys(
            forAny: [deviceId] + fallbackPeerIDs,
            pinnedProtocolFingerprints: pinnedFingerprints
        )
        let joinBootstrap = await KEMTrustStore.shared.authorityBoundBootstrapKEMPublicKeys(
            forAny: [deviceId] + fallbackPeerIDs,
            pinnedProtocolFingerprints: pinnedFingerprints
        )
        return joinBootstrap.merging(signedRefresh) { _, signed in signed }
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        nil
    }

    func requiresPinnedProtocolIdentity(for deviceId: String) async -> Bool {
        _ = deviceId
        return expectedRemoteAuthority != nil
    }
}
