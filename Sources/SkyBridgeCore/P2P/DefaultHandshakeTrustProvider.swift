import Foundation

@available(macOS 14.0, iOS 17.0, *)
struct DefaultHandshakeTrustProvider: HandshakeTrustProvider, Sendable {
    private func trimmedNonEmpty(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        return raw
    }

    private func normalizeBonjourIdentifier(_ identifier: String) -> String? {
        guard identifier.hasPrefix("bonjour:") else { return nil }
        let payload = String(identifier.dropFirst("bonjour:".count))
        let pieces = payload.split(separator: "@", maxSplits: 1).map(String.init)
        guard let rawName = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            return nil
        }
        let rawDomain = pieces.count > 1 ? pieces[1] : "local"
        let domain = rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "local"
            : rawDomain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "bonjour:\(rawName)@\(domain)"
    }

    private func trustLookupCandidates(for deviceId: String) -> [String] {
        var ordered: [String] = []
        var seen: Set<String> = []

        func append(_ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return }
            guard !seen.contains(value) else { return }
            seen.insert(value)
            ordered.append(value)
        }

        func appendDerived(from identifier: String) {
            append(identifier)

            if identifier.hasPrefix("recent:") {
                let inner = String(identifier.dropFirst("recent:".count))
                append(inner)
                appendDerived(from: inner)
            }

            if identifier.hasPrefix("id:") {
                append(String(identifier.dropFirst("id:".count)))
            }

            if identifier.hasPrefix("mac:bonjour:") {
                append(String(identifier.dropFirst("mac:".count)))
            }

            if identifier.hasPrefix("fp:") {
                append(String(identifier.dropFirst("fp:".count)))
            }

            if identifier.hasPrefix("name:") {
                append(String(identifier.dropFirst("name:".count)))
            }

            if let normalizedBonjour = normalizeBonjourIdentifier(identifier) {
                append(normalizedBonjour)
            }
        }

        appendDerived(from: deviceId)
        return ordered
    }

    private func capabilityValue(prefix: String, in capabilities: [String]) -> String? {
        for capability in capabilities {
            guard capability.hasPrefix(prefix) else { continue }
            let value = String(capability.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty {
                return value
            }
        }
        return nil
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

            if normalizedCandidates.contains(record.deviceId) {
                matched[record.deviceId] = record
                continue
            }

            if let peerEndpoint = capabilityValue(prefix: "peerEndpoint=", in: record.capabilities),
               normalizedCandidates.contains(peerEndpoint) {
                matched[record.deviceId] = record
                continue
            }

            if let declaredDeviceId = capabilityValue(prefix: "declaredDeviceId=", in: record.capabilities),
               normalizedCandidates.contains(declaredDeviceId) {
                matched[record.deviceId] = record
                continue
            }

            if let deviceName = trimmedNonEmpty(record.deviceName),
               normalizedCandidatesLower.contains(deviceName.lowercased()) {
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
