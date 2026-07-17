import Foundation

enum P2PDiscoveryKEMAliasRepairPolicy {
    static func handshakeDeviceIdentifier(for device: DiscoveredDevice) -> String {
        if let persistentDeviceId = device.deviceId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !persistentDeviceId.isEmpty {
            return persistentDeviceId
        }
        if let uniqueIdentifier = device.uniqueIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !uniqueIdentifier.isEmpty {
            return uniqueIdentifier
        }
        return device.id.uuidString
    }

    static func aliasRepairCandidates(for device: DiscoveredDevice) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ raw: String?) {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else {
                return
            }
            if seen.insert(trimmed).inserted {
                ordered.append(trimmed)
            }
            let lowercased = trimmed.lowercased()
            if lowercased != trimmed, seen.insert(lowercased).inserted {
                ordered.append(lowercased)
            }
        }

        func appendLookupCandidates(_ raw: String?) {
            for candidate in PeerTrustLookup.lookupCandidates(for: raw) {
                append(candidate)
            }
        }

        append(handshakeDeviceIdentifier(for: device))
        appendLookupCandidates(device.deviceId)
        appendLookupCandidates(device.uniqueIdentifier)
        appendLookupCandidates(device.id.uuidString)
        appendLookupCandidates(device.ipv4)
        appendLookupCandidates(device.ipv6)
        return ordered
    }

    static func uniqueTrustRecord(
        for device: DiscoveredDevice,
        records: [TrustRecord]
    ) -> TrustRecord? {
        let aliases = aliasRepairCandidates(for: device)
        let candidateSet = Set(aliases)
        let candidateLowercased = Set(aliases.map { $0.lowercased() })
        let displayNames = trustDisplayNameCandidates(for: device)

        var matchesByDeviceId: [String: TrustRecord] = [:]
        for record in records where record.isAuthenticationEligible {
            guard let kemKeys = record.kemPublicKeys,
                  !KEMPublicKeyInfo.normalizedValidKeys(kemKeys).isEmpty else {
                continue
            }
            guard PeerTrustLookup.recordMatches(
                record,
                candidates: candidateSet,
                candidateLowercased: candidateLowercased,
                candidateDisplayNamesLower: displayNames
            ) else {
                continue
            }
            matchesByDeviceId[record.deviceId] = record
        }

        guard matchesByDeviceId.count == 1 else { return nil }
        return matchesByDeviceId.values.first
    }

    static func kemPublicKeys(from keysBySuite: [CryptoSuite: Data]) -> [KEMPublicKeyInfo] {
        keysBySuite
            .filter { !$0.value.isEmpty }
            .map { KEMPublicKeyInfo(suiteWireId: $0.key.wireId, publicKey: $0.value) }
            .sorted { $0.suiteWireId < $1.suiteWireId }
    }

    private static func trustDisplayNameCandidates(for device: DiscoveredDevice) -> Set<String> {
        var names = Set<String>()

        func append(_ raw: String?) {
            guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else {
                return
            }
            names.insert(value.lowercased())

            while true {
                if let stripped = stripTrailingOSVersionSuffix(from: value) {
                    value = stripped
                    names.insert(value.lowercased())
                    continue
                }
                if let stripped = stripTrailingBracketSuffix(from: value, open: "(", close: ")") {
                    value = stripped
                    names.insert(value.lowercased())
                    continue
                }
                if let stripped = stripTrailingBracketSuffix(from: value, open: "[", close: "]") {
                    value = stripped
                    names.insert(value.lowercased())
                    continue
                }
                if let stripped = stripTrailingBracketSuffix(from: value, open: "【", close: "】") {
                    value = stripped
                    names.insert(value.lowercased())
                    continue
                }
                break
            }

            for suffix in [" 📱", " 🍎"] where value.hasSuffix(suffix) {
                let stripped = String(value.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                if !stripped.isEmpty {
                    names.insert(stripped.lowercased())
                }
            }
        }

        append(device.name)
        append(PeerTrustLookup.sanitizedBonjourServiceInstanceName(device.uniqueIdentifier))
        return names
    }

    private static func stripTrailingOSVersionSuffix(from raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns = [
            #"\s*(?:[.\-_,|/])?\s*(?:iOS|iPadOS|macOS|visionOS|tvOS|watchOS)\s+\d+(?:\.\d+){0,2}(?:\s*\(Build\s+[^)]+\)|\s+Build\s+\S+)?$"#,
            #"\s*(?:[.\-_,|/])?\s*Version\s+\d+(?:\.\d+){0,2}(?:\s*\(Build\s+[^)]+\)|\s+Build\s+\S+)?$"#
        ]

        for pattern in patterns {
            guard let range = value.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) else {
                continue
            }
            let prefix = value[..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prefix.isEmpty else { continue }
            return String(prefix)
        }
        return nil
    }

    private static func stripTrailingBracketSuffix(from raw: String, open: Character, close: Character) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.last == close else { return nil }
        guard let openIndex = value.lastIndex(of: open), openIndex > value.startIndex else { return nil }

        let prefix = value[..<openIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prefix.isEmpty else { return nil }
        return String(prefix)
    }
}
