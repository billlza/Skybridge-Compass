import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct DefaultHandshakeTrustProvider: HandshakeTrustProvider, Sendable {
    private func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
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
            if let direct = TrustSyncService.shared.getTrustRecord(deviceId: deviceId),
               let fp = trimmedNonEmpty(direct.pubKeyFP) {
                return fp
            }

            let matches = matchingTrustRecords(for: deviceId)
            let fingerprints = Set(matches.compactMap { record in
                trimmedNonEmpty(record.pubKeyFP)?.lowercased()
            })

            // Avoid accidental mis-pinning: only pin when the candidate set resolves to one fingerprint.
            guard fingerprints.count == 1, let fingerprint = fingerprints.first else {
                return nil
            }

            return matches.compactMap { trimmedNonEmpty($0.pubKeyFP) }
                .first { $0.caseInsensitiveCompare(fingerprint) == .orderedSame }
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
