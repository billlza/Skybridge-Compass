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

        for candidate in candidates {
            var dict: [UInt16: Data] = cache[candidate]?.keys ?? [:]
            for keyInfo in kemPublicKeys {
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

    private static func loadCache(storageKey: String, userDefaults: UserDefaults) -> [String: StoredPeer] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredPeer].self, from: data)) ?? [:]
    }

    private func save() {
        let data = (try? JSONEncoder().encode(cache)) ?? Data()
        userDefaults.set(data, forKey: storageKey)
    }
}
