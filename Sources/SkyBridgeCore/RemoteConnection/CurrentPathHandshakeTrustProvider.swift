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
struct CurrentPathHandshakeTrustProvider: MultiFingerprintHandshakeTrustProvider, Sendable {
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

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        let merged = await PeerKEMBootstrapStore.shared.mergedKEMPublicKeys(
            forCandidates: candidateDeviceIds(for: deviceId)
        )
        return merged.reduce(into: [:]) { partialResult, item in
            partialResult[CryptoSuite(wireId: item.key)] = item.value
        }
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        nil
    }
}
