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

    private let storageKey = "kem_trust_store.v1"
    private var cache: [String: StoredPeer] = [:] // deviceId -> StoredPeer

    private init() {
        cache = Self.loadCache(storageKey: storageKey)
    }

    public func upsert(deviceId: String, kemPublicKeys: [KEMPublicKeyInfo]) {
        guard !deviceId.isEmpty else { return }
        var dict: [UInt16: Data] = cache[deviceId]?.keys ?? [:]
        for k in kemPublicKeys {
            dict[k.suiteWireId] = k.publicKey
        }
        cache[deviceId] = StoredPeer(keys: dict, updatedAt: Date())
        save()
    }

    public func kemPublicKeys(for deviceId: String) -> [CryptoSuite: Data] {
        guard let stored = cache[deviceId] else { return [:] }
        var result: [CryptoSuite: Data] = [:]
        for (wireId, pk) in stored.keys {
            result[CryptoSuite(wireId: wireId)] = pk
        }
        return result
    }

    public func clear(deviceId: String) {
        cache.removeValue(forKey: deviceId)
        save()
    }

    private static func loadCache(storageKey: String) -> [String: StoredPeer] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredPeer].self, from: data)) ?? [:]
    }

    private func save() {
        let data = (try? JSONEncoder().encode(cache)) ?? Data()
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

