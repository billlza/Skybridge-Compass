import Foundation

@available(macOS 14.0, iOS 17.0, *)
public actor PeerKEMBootstrapStore {
    public static let shared = PeerKEMBootstrapStore()

    private struct Entry: Codable, Sendable {
        var kemPublicKeys: [UInt16: Data]
        var updatedAt: Date
    }

    private struct Snapshot: Codable, Sendable {
        var entries: [String: Entry]
    }

    private static let defaultsKey = "com.skybridge.p2p.bootstrap_kem_store.v1"
    private let defaults: UserDefaults
    private var entries: [String: Entry]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.loadEntries(from: defaults)
    }

    public func upsert(deviceIds: [String], kemPublicKeys: [KEMPublicKeyInfo]) {
        let normalizedIds = normalizedUniqueIds(deviceIds)
        guard !normalizedIds.isEmpty else { return }

        let incoming = incomingKEMMap(kemPublicKeys)
        guard !incoming.isEmpty else { return }

        let now = Date()
        var changed = false

        for deviceId in normalizedIds {
            let existingKeys = entries[deviceId]?.kemPublicKeys ?? [:]
            var merged = existingKeys
            for (suiteWireId, publicKey) in incoming {
                merged[suiteWireId] = publicKey
            }

            if merged != existingKeys || entries[deviceId] == nil {
                entries[deviceId] = Entry(kemPublicKeys: merged, updatedAt: now)
                changed = true
            } else if var current = entries[deviceId] {
                current.updatedAt = now
                entries[deviceId] = current
            }
        }

        if changed {
            trimIfNeeded(maxEntries: 1024)
            persist()
        }
    }

    public func mergedKEMPublicKeys(forCandidates candidates: [String]) -> [UInt16: Data] {
        let normalizedCandidates = normalizedUniqueIds(candidates)
        guard !normalizedCandidates.isEmpty else { return [:] }

        var merged: [UInt16: Data] = [:]
        for candidate in normalizedCandidates {
            guard let entry = entries[candidate] else { continue }
            for (suiteWireId, publicKey) in entry.kemPublicKeys where merged[suiteWireId] == nil {
                merged[suiteWireId] = publicKey
            }
        }
        return merged
    }

    public func availableSuiteWireIds(forCandidates candidates: [String]) -> [UInt16] {
        Array(mergedKEMPublicKeys(forCandidates: candidates).keys).sorted()
    }

    func clearForTesting() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func normalizedUniqueIds(_ rawIds: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for raw in rawIds {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if seen.insert(trimmed).inserted {
                result.append(trimmed)
            }
        }

        return result
    }

    private func incomingKEMMap(_ kemPublicKeys: [KEMPublicKeyInfo]) -> [UInt16: Data] {
        var result: [UInt16: Data] = [:]
        for key in kemPublicKeys where !key.publicKey.isEmpty {
            result[key.suiteWireId] = key.publicKey
        }
        return result
    }

    private func trimIfNeeded(maxEntries: Int) {
        guard entries.count > maxEntries else { return }
        let sortedByAge = entries.sorted { $0.value.updatedAt < $1.value.updatedAt }
        let toRemove = entries.count - maxEntries
        for (deviceId, _) in sortedByAge.prefix(toRemove) {
            entries.removeValue(forKey: deviceId)
        }
    }

    private func persist() {
        do {
            let snapshot = Snapshot(entries: entries)
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: Self.defaultsKey)
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Failed to persist bootstrap KEM cache: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private static func loadEntries(from defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            return snapshot.entries
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Failed to load bootstrap KEM cache: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }
}
