import Foundation

@available(macOS 14.0, iOS 17.0, *)
public actor PeerProtocolIdentityBootstrapStore {
    public static let shared = PeerProtocolIdentityBootstrapStore()

    private struct Entry: Codable, Sendable {
        var fingerprints: [String]
        var updatedAt: Date
    }

    private struct Snapshot: Codable, Sendable {
        var entries: [String: Entry]
    }

    private static let defaultsKey = "com.skybridge.p2p.bootstrap_protocol_identity_store.v1"
    private let defaults: UserDefaults
    private var entries: [String: Entry]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.loadEntries(from: defaults)
    }

    public func upsert(deviceIds: [String], fingerprints: Set<String>) {
        let normalizedIds = trustMaterialIds(deviceIds)
        let incoming = Set(fingerprints.compactMap(Self.normalizedFingerprint))
        guard !normalizedIds.isEmpty, !incoming.isEmpty else { return }

        let now = Date()
        var changed = false

        for deviceId in normalizedIds {
            let existing = Set(entries[deviceId]?.fingerprints ?? [])
            if incoming != existing || entries[deviceId] == nil {
                entries[deviceId] = Entry(fingerprints: Array(incoming).sorted(), updatedAt: now)
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

    public func trustedFingerprints(forCandidates candidates: [String]) -> Set<String> {
        let normalizedCandidates = trustMaterialIds(candidates)
        guard !normalizedCandidates.isEmpty else { return [] }

        var fingerprints = Set<String>()
        for candidate in normalizedCandidates {
            guard let entry = entries[candidate] else { continue }
            fingerprints.formUnion(entry.fingerprints.compactMap(Self.normalizedFingerprint))
        }
        return fingerprints
    }

    public func containsTrustedFingerprint(_ fingerprint: String) -> Bool {
        guard let normalized = Self.normalizedFingerprint(fingerprint) else {
            return false
        }
        return entries.values.contains { entry in
            entry.fingerprints.contains(normalized)
        }
    }

    public func clear(deviceIds: [String]) {
        do {
            try clearPersisting(deviceIds: deviceIds)
        } catch {
            SkyBridgeLogger.p2p.error(
                "Failed to clear bootstrap protocol identity cache: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    public func clearPersisting(deviceIds: [String]) throws {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else { return }

        var updatedEntries = entries
        var changed = false
        for deviceId in normalizedIds {
            if updatedEntries.removeValue(forKey: deviceId) != nil {
                changed = true
            }
        }

        guard changed else { return }
        try persist(updatedEntries)
        entries = updatedEntries
    }

    func clearForTesting() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func trustMaterialIds(_ rawIds: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in rawIds {
            for candidate in PeerTrustLookup.lookupCandidates(for: raw)
            where !PeerTrustLookup.isEndpointAlias(candidate) && seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
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
            try persist(entries)
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Failed to persist bootstrap protocol identity cache: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func persist(_ snapshotEntries: [String: Entry]) throws {
        if snapshotEntries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        let snapshot = Snapshot(entries: snapshotEntries)
        let data = try JSONEncoder().encode(snapshot)
        defaults.set(data, forKey: Self.defaultsKey)
    }

    private static func loadEntries(from defaults: UserDefaults) -> [String: Entry] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        do {
            let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            return snapshot.entries
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Failed to load bootstrap protocol identity cache: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }
}
