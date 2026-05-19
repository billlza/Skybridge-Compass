import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct DefaultHandshakeTrustProvider: MultiFingerprintHandshakeTrustProvider, Sendable {
    private let trustRecordsSnapshot: [TrustRecord]?

    init(trustRecordsSnapshot: [TrustRecord]? = nil) {
        self.trustRecordsSnapshot = trustRecordsSnapshot
    }

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
        let fingerprints = resolvedTrustedFingerprints(
            directRecord: directRecord,
            matchingRecords: matchingRecords
        )
        guard fingerprints.count == 1, let fingerprint = fingerprints.first else {
            return nil
        }
        return fingerprint
    }

    func resolvedTrustedFingerprints(
        directRecord: TrustRecord?,
        matchingRecords: [TrustRecord]
    ) -> Set<String> {
        var recordsById: [String: TrustRecord] = [:]
        if let directRecord {
            recordsById[directRecord.deviceId] = directRecord
        }
        for record in matchingRecords where recordsById[record.deviceId] == nil {
            recordsById[record.deviceId] = record
        }

        let records = Array(recordsById.values)
        guard !records.isEmpty else { return [] }

        let canonicalDeviceIds = Set(records.compactMap(canonicalTrustedDeviceId(for:)))
        guard canonicalDeviceIds.count <= 1 else {
            return []
        }

        var fingerprintsByAlgorithm: [String: Set<String>] = [:]
        for record in records {
            if let fingerprint = authoritativeProtocolFingerprint(for: record) {
                let algorithm = record.protocolSigningAlgorithm?.rawValue ?? "unknown"
                fingerprintsByAlgorithm[algorithm, default: []].insert(fingerprint)
            }
        }

        guard !fingerprintsByAlgorithm.values.contains(where: { $0.count > 1 }) else {
            return []
        }

        return Set(fingerprintsByAlgorithm.values.flatMap { $0 })
    }

    private func canonicalTrustedDeviceId(for record: TrustRecord) -> String? {
        let candidates = [record.currentDeviceId, record.deviceId]
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let persistent = PeerTrustLookup.persistentDeviceId(from: trimmed) {
                return persistent.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            }
            return trimmed.lowercased()
        }
        return nil
    }

    private func trustLookupCandidates(for deviceId: String) -> [String] {
        var candidates = PeerTrustLookup.lookupCandidates(for: deviceId)
        let trimmed = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !candidates.contains(trimmed) {
            candidates.append(trimmed)
        }
        let lowercased = trimmed.lowercased()
        if !lowercased.isEmpty, !candidates.contains(lowercased) {
            candidates.append(lowercased)
        }
        if let persistent = PeerTrustLookup.persistentDeviceId(from: trimmed),
           !candidates.contains(persistent) {
            candidates.append(persistent)
        }
        return candidates
    }

    private func matchingTrustRecordsSnapshot(
        _ records: [TrustRecord],
        for deviceId: String
    ) -> [TrustRecord] {
        let candidates = trustLookupCandidates(for: deviceId)
        let normalizedCandidates = Set(candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty })
        guard !normalizedCandidates.isEmpty else { return [] }
        let normalizedCandidatesLower = Set(normalizedCandidates.map { $0.lowercased() })

        var matched: [String: TrustRecord] = [:]

        for record in records where !record.isTombstone {
            if matched[record.deviceId] != nil {
                continue
            }

            if normalizedCandidatesLower.contains(record.deviceId.lowercased()) {
                matched[record.deviceId] = record
                continue
            }

            let currentDeviceId = record.currentDeviceId.trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentDeviceId.isEmpty,
               normalizedCandidatesLower.contains(currentDeviceId.lowercased()) {
                matched[record.deviceId] = record
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
        let records = await trustRecords()
        let directRecord = directRecord(for: deviceId, in: records)
        return resolvedTrustedFingerprint(
            directRecord: directRecord,
            matchingRecords: matchingTrustRecordsSnapshot(records, for: deviceId)
        )
    }

    func trustedFingerprints(for deviceId: String) async -> Set<String> {
        let records = await trustRecords()
        let directRecord = directRecord(for: deviceId, in: records)
        let trusted = resolvedTrustedFingerprints(
            directRecord: directRecord,
            matchingRecords: matchingTrustRecordsSnapshot(records, for: deviceId)
        )
        guard !trusted.isEmpty else { return [] }

        let cached = await PeerProtocolIdentityBootstrapStore.shared.trustedFingerprints(
            forCandidates: trustLookupCandidates(for: deviceId)
        )
        guard !cached.isEmpty else { return trusted }
        guard !trusted.isDisjoint(with: cached) else {
            SkyBridgeLogger.p2p.warning(
                "⚠️ cached protocol identity pins ignored because they are not bound to existing trust: device=\(deviceId, privacy: .public)"
            )
            return trusted
        }

        return trusted.union(cached)
    }

    private func trustRecords() async -> [TrustRecord] {
        if let trustRecordsSnapshot {
            return trustRecordsSnapshot.filter { !$0.isTombstone && !$0.isExpired }
        }
        return await MainActor.run {
            TrustSyncService.shared.activeTrustRecords
        }
    }

    private func directRecord(for deviceId: String, in records: [TrustRecord]) -> TrustRecord? {
        let normalized = deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        return records.first {
            !$0.isTombstone
                && !$0.isExpired
                && $0.deviceId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized
        }
    }

    func trustedKEMPublicKeys(for deviceId: String) async -> [CryptoSuite: Data] {
        let recordsSnapshot = await trustRecords()
        let candidates = trustLookupCandidates(for: deviceId)
        var groupedKeys: [CryptoSuite: Set<Data>] = [:]
        let records = matchingTrustRecordsSnapshot(recordsSnapshot, for: deviceId)
            .sorted { $0.updatedAt > $1.updatedAt }

        for record in records {
            guard let kemKeys = record.kemPublicKeys else { continue }
            for key in KEMPublicKeyInfo.normalizedValidKeys(kemKeys) {
                let suite = CryptoSuite(wireId: key.suiteWireId)
                groupedKeys[suite, default: []].insert(key.publicKey)
            }
        }

        var result: [CryptoSuite: Data] = [:]
        var conflictedSuites = Set<CryptoSuite>()
        for (suite, keys) in groupedKeys {
            if keys.count == 1, let publicKey = keys.first {
                result[suite] = publicKey
            } else if keys.count > 1 {
                conflictedSuites.insert(suite)
            }
        }

        var merged = result
        if !conflictedSuites.isEmpty {
            let conflictedSummary = conflictedSuites
                .map(\.rawValue)
                .sorted()
                .map { String($0) }
                .joined(separator: ",")
            SkyBridgeLogger.p2p.warning(
                "⚠️ conflicting trusted KEM keys detected; deferring to bootstrap cache or fresh exchange: device=\(deviceId, privacy: .public) suites=\(conflictedSummary, privacy: .public)"
            )
        }
        let cached = await PeerKEMBootstrapStore.shared.mergedKEMPublicKeys(
            forCandidates: candidates
        )
        for (suiteWireId, publicKey) in cached {
            let suite = CryptoSuite(wireId: suiteWireId)
            if conflictedSuites.contains(suite) || merged[suite] == nil {
                merged[suite] = publicKey
            }
        }
        return merged
    }

    func trustedSecureEnclavePublicKey(for deviceId: String) async -> Data? {
        let recordsSnapshot = await trustRecords()
        if let direct = directRecord(for: deviceId, in: recordsSnapshot),
           let se = direct.secureEnclavePublicKey,
           !se.isEmpty {
            return se
        }

        let records = matchingTrustRecordsSnapshot(recordsSnapshot, for: deviceId)
            .sorted { $0.updatedAt > $1.updatedAt }
        for record in records {
            if let se = record.secureEnclavePublicKey, !se.isEmpty {
                return se
            }
        }
        return nil
    }
}
