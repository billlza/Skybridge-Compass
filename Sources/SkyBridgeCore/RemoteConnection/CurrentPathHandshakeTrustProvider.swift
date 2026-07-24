import Foundation
import SkyBridgeProtocolCore

struct CurrentPathRemoteAuthority: Sendable, Equatable {
    let deviceId: String
    let protocolSigningAlgorithm: ProtocolSigningAlgorithm
    let protocolPublicKeyFingerprint: String
    let protocolPublicKeyBytes: Data?
    let deviceName: String?
}

@available(macOS 14.0, iOS 17.0, *)
struct CurrentPathHandshakeTrustProvider: MultiFingerprintHandshakeTrustProvider, ExactProtocolIdentityHandshakeTrustProvider, Sendable {
    let expectedRemoteAuthority: CurrentPathRemoteAuthority?
    let fallbackPeerIDs: [String]
    let additionalTrustedFingerprints: Set<String>

    private func candidateDeviceIds(for requestedDeviceId: String) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        let rawValues: [String?] = [requestedDeviceId, expectedRemoteAuthority?.deviceId] + fallbackPeerIDs.map(Optional.some)
        for raw in rawValues {
            guard let raw else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
        }
        return ordered
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

    func trustedProtocolIdentityRawKeys(for deviceId: String) async -> [TrustedProtocolIdentityRawKey] {
        guard let expectedRemoteAuthority,
              deviceId == expectedRemoteAuthority.deviceId || fallbackPeerIDs.contains(deviceId),
              let publicKey = expectedRemoteAuthority.protocolPublicKeyBytes,
              !publicKey.isEmpty else {
            return []
        }
        let identity = IdentityPublicKeys(
            protocolPublicKey: publicKey,
            protocolAlgorithm: expectedRemoteAuthority.protocolSigningAlgorithm.wire
        )
        guard (try? identity.authoritativeProtocolFingerprint().lowercased())
                == expectedRemoteAuthority.protocolPublicKeyFingerprint
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() else {
            return []
        }
        return [
            TrustedProtocolIdentityRawKey(
                algorithm: expectedRemoteAuthority.protocolSigningAlgorithm,
                publicKey: publicKey
            )
        ]
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        let pinnedFingerprints = await trustedFingerprints(for: deviceId)
        let candidates = candidateDeviceIds(for: deviceId)
        // Tier 1 (preferred): signed LAN KEM refresh material bound to the pinned protocol identity.
        var merged = await PeerKEMBootstrapStore.shared.signedRefreshKEMPublicKeys(
            forCandidates: candidates,
            pinnedProtocolFingerprints: pinnedFingerprints
        )
        // Tier 2: pairing-identity-exchange KEM, returned only for entries whose recorded protocol
        // fingerprint matches the pinned current-path authority. This unblocks the strict-PQC initial
        // handshake (the signed-refresh tier only populates over the already-encrypted DataChannel,
        // i.e. after the handshake). Signed-refresh keys win on suite-id conflicts.
        let authorityBound = await PeerKEMBootstrapStore.shared.authorityBoundPairingKEMPublicKeys(
            forCandidates: candidates,
            pinnedProtocolFingerprints: pinnedFingerprints
        )
        for (suiteWireId, publicKey) in authorityBound where merged[suiteWireId] == nil {
            merged[suiteWireId] = publicKey
        }
        return merged.reduce(into: [:]) { partialResult, item in
            partialResult[CryptoSuite(wireId: item.key)] = item.value
        }
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        nil
    }

    func requiresPinnedProtocolIdentity(for deviceId: String) async -> Bool {
        _ = deviceId
        return expectedRemoteAuthority != nil
    }
}
