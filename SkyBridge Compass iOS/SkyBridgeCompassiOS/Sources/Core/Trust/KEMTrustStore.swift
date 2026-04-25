import Foundation

/// Stores peer KEM identity public keys by deviceId.
/// This is the missing prerequisite for negotiating PQC suites (initiator needs peer KEM public key).
@available(iOS 17.0, *)
public actor KEMTrustStore {
    public static let shared = KEMTrustStore()

    private struct StoredPeer: Codable, Sendable {
        var keys: [UInt16: Data] // suiteWireId -> publicKey
        var updatedAt: Date
    }

    private let storageKey: String
    private let userDefaults: UserDefaults
    private var cache: [String: StoredPeer] = [:] // deviceId -> StoredPeer

    init(
        storageKey: String = "kem_trust_store.v1",
        userDefaults: UserDefaults = .standard
    ) {
        self.storageKey = storageKey
        self.userDefaults = userDefaults
        cache = Self.loadCache(storageKey: storageKey, userDefaults: userDefaults)
    }

    public func upsert(deviceId: String, kemPublicKeys: [KEMPublicKeyInfo]) {
        let candidates = PeerIdentityAliasResolver.lookupCandidates(for: deviceId)
        guard !candidates.isEmpty else { return }
        let validKeys = KEMPublicKeyInfo.normalizedValidKeys(kemPublicKeys)
        guard !validKeys.isEmpty else { return }

        for candidate in candidates {
            var dict: [UInt16: Data] = cache[candidate]?.keys ?? [:]
            for keyInfo in validKeys {
                dict[keyInfo.suiteWireId] = keyInfo.publicKey
            }
            cache[candidate] = StoredPeer(keys: dict, updatedAt: Date())
        }
        save()
    }

    public func kemPublicKeys(for deviceId: String) -> [CryptoSuite: Data] {
        var result: [CryptoSuite: Data] = [:]
        for candidate in PeerIdentityAliasResolver.lookupCandidates(for: deviceId) {
            guard let stored = cache[candidate] else { continue }
            for (wireId, pk) in stored.keys {
                let suite = CryptoSuite(wireId: wireId)
                if result[suite] == nil {
                    result[suite] = pk
                }
            }
        }
        return result
    }

    public func clear(deviceId: String) {
        for candidate in PeerIdentityAliasResolver.lookupCandidates(for: deviceId) {
            cache.removeValue(forKey: candidate)
        }
        save()
    }

    public func rebindCanonicalDeviceId(_ canonicalDeviceId: String, legacyIdentifiers: [String]) {
        guard let canonical = PeerIdentityAliasResolver.persistentDeviceId(from: canonicalDeviceId) else {
            return
        }

        let canonicalCandidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: canonical))
        let migrationCandidates = Self.orderedMigrationCandidates(
            canonicalDeviceId: canonical,
            legacyIdentifiers: legacyIdentifiers
        )

        var mergedKeys: [UInt16: (publicKey: Data, updatedAt: Date, isCanonical: Bool)] = [:]
        for candidate in migrationCandidates {
            guard let stored = cache[candidate] else { continue }
            let isCanonicalCandidate = canonicalCandidates.contains(candidate)
            for (wireId, publicKey) in stored.keys {
                if let existing = mergedKeys[wireId] {
                    if stored.updatedAt > existing.updatedAt
                        || (stored.updatedAt == existing.updatedAt
                            && isCanonicalCandidate
                            && !existing.isCanonical) {
                        mergedKeys[wireId] = (publicKey, stored.updatedAt, isCanonicalCandidate)
                    }
                } else {
                    mergedKeys[wireId] = (publicKey, stored.updatedAt, isCanonicalCandidate)
                }
            }
        }
        guard !mergedKeys.isEmpty else { return }

        let rebound = StoredPeer(
            keys: Dictionary(uniqueKeysWithValues: mergedKeys.map { ($0.key, $0.value.publicKey) }),
            updatedAt: mergedKeys.values.map(\.updatedAt).max() ?? Date()
        )
        for candidate in Set(migrationCandidates) where !canonicalCandidates.contains(candidate) {
            cache.removeValue(forKey: candidate)
        }
        for candidate in canonicalCandidates {
            cache[candidate] = rebound
        }
        save()
    }

#if DEBUG
    public func clearForTesting() {
        cache.removeAll()
        save()
    }
#endif

    private static func loadCache(storageKey: String, userDefaults: UserDefaults) -> [String: StoredPeer] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredPeer].self, from: data)) ?? [:]
    }

    private static func migrationCandidates(for identifier: String) -> [String] {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            ordered.append(value)
        }

        for candidate in PeerIdentityAliasResolver.lookupCandidates(for: trimmed) {
            append(candidate)
        }

        let normalized = trimmed.lowercased()
        append(normalized)
        append("host:\(normalized)")
        return ordered
    }

    private static func orderedMigrationCandidates(
        canonicalDeviceId: String,
        legacyIdentifiers: [String]
    ) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        for raw in [canonicalDeviceId] + legacyIdentifiers {
            for candidate in migrationCandidates(for: raw) where seen.insert(candidate).inserted {
                ordered.append(candidate)
            }
        }

        return ordered
    }

    private func save() {
        let data = (try? JSONEncoder().encode(cache)) ?? Data()
        userDefaults.set(data, forKey: storageKey)
    }
}
