import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct DefaultHandshakeTrustProvider: HandshakeTrustProvider, Sendable {
    private func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    func authoritativeProtocolFingerprint(for record: TrustRecord) -> String? {
        if let fingerprint = trimmedNonEmpty(record.currentPathAuthorityFingerprint) {
            return fingerprint.lowercased()
        }

        guard let protocolPublicKey = record.protocolPublicKey,
              !protocolPublicKey.isEmpty,
              let algorithm = record.protocolSigningAlgorithm else {
            return nil
        }

        let identityKeys = IdentityPublicKeys(
            protocolPublicKey: protocolPublicKey,
            protocolAlgorithm: algorithm.wire
        )
        return try? identityKeys.authoritativeProtocolFingerprint().lowercased()
    }

    func resolvedTrustedFingerprint(
        directRecord: TrustRecord?,
        matchingRecords: [TrustRecord]
    ) -> String? {
        if let directRecord,
           let fingerprint = authoritativeProtocolFingerprint(for: directRecord) {
            return fingerprint
        }

        let fingerprints = Set(matchingRecords.compactMap { record in
            authoritativeProtocolFingerprint(for: record)
        })

        // Avoid accidental mis-pinning: only pin when the candidate set resolves to one
        // authoritative protocol-signing fingerprint. Legacy discovery pubKeyFP is not a
        // valid substitute here because it may refer to a different key family entirely.
        guard fingerprints.count == 1, let fingerprint = fingerprints.first else {
            return nil
        }

        return matchingRecords.compactMap { authoritativeProtocolFingerprint(for: $0) }
            .first { $0.caseInsensitiveCompare(fingerprint) == .orderedSame }
    }

    private func trustLookupCandidates(for deviceId: String) -> [String] {
        PeerTrustLookup.lookupCandidates(for: deviceId)
    }

    private func capabilityValue(prefix: String, in capabilities: [String]) -> String? {
        PeerTrustLookup.capabilityValue(prefix: prefix, in: capabilities)
    }

    @MainActor
    private func matchingTrustRecords(for deviceId: String) -> [TrustRecord] {
        let candidates = trustLookupCandidates(for: deviceId)
        let normalizedCandidates = Set(candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard !normalizedCandidates.isEmpty else { return [] }
        let normalizedCandidatesLower = Set(normalizedCandidates.map { $0.lowercased() })

        var matched: [String: TrustRecord] = [:]

        for candidate in normalizedCandidates {
            if let record = TrustSyncService.shared.getTrustRecord(deviceId: candidate) {
                matched[record.deviceId] = record
            }
        }

        for record in TrustSyncService.shared.activeTrustRecords where !record.isTombstone {
            if matched[record.deviceId] != nil {
                continue
            }

            if PeerTrustLookup.recordMatches(
                record,
                candidates: normalizedCandidates,
                candidateLowercased: normalizedCandidatesLower
            ) {
                matched[record.deviceId] = record
            }
        }

        return Array(matched.values)
    }

    func trustedFingerprint(for deviceId: String) async -> String? {
        await MainActor.run {
            resolvedTrustedFingerprint(
                directRecord: TrustSyncService.shared.getTrustRecord(deviceId: deviceId),
                matchingRecords: matchingTrustRecords(for: deviceId)
            )
        }
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        let trustResult = await MainActor.run { () -> ([CryptoSuite: Data], [String]) in
            var result: [CryptoSuite: Data] = [:]
            let candidates = trustLookupCandidates(for: deviceId)
            let records = matchingTrustRecords(for: deviceId)
                .sorted { $0.updatedAt > $1.updatedAt }

            for record in records {
                guard let kemKeys = record.kemPublicKeys else { continue }
                for key in kemKeys {
                    let suite = CryptoSuite(wireId: key.suiteWireId)
                    if result[suite] == nil {
                        result[suite] = key.publicKey
                    }
                }
            }
            return (result, candidates)
        }

        var merged = trustResult.0
        let cached = await PeerKEMBootstrapStore.shared.mergedKEMPublicKeys(
            forCandidates: trustResult.1
        )
        for (suiteWireId, publicKey) in cached {
            let suite = CryptoSuite(wireId: suiteWireId)
            if merged[suite] == nil {
                merged[suite] = publicKey
            }
        }
        return merged
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        await MainActor.run {
            if let direct = TrustSyncService.shared.getTrustRecord(deviceId: deviceId),
               let se = direct.secureEnclavePublicKey,
               !se.isEmpty {
                return se
            }

            let records = matchingTrustRecords(for: deviceId)
                .sorted { $0.updatedAt > $1.updatedAt }
            for record in records {
                if let se = record.secureEnclavePublicKey, !se.isEmpty {
                    return se
                }
            }
            return nil
        }
    }
}
