import Foundation

/// Derived bootstrap-admission cache populated only after protocol identity authority
/// is committed to `TrustSyncService`. It is not the authority store: persistence
/// failure is observable, the current process may keep the derived entry, and a later
/// process fails closed until the cache is rebuilt from an authoritative approval.
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
#if DEBUG || SKYBRIDGE_TESTING
    private var persistenceResultOverrideForTesting: Bool?
#endif

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.loadEntries(from: defaults)
    }

    @discardableResult
    public func upsert(deviceIds: [String], fingerprints: Set<String>) -> Bool {
        let normalizedIds = trustMaterialIds(deviceIds)
        let incoming = Set(fingerprints.compactMap(Self.normalizedFingerprint))
        guard !normalizedIds.isEmpty, !incoming.isEmpty else { return false }

        let now = Date()
        var changed = false

        for deviceId in normalizedIds {
            let existing = Set(entries[deviceId]?.fingerprints ?? [])
            let merged = existing.union(incoming)
            if merged != existing || entries[deviceId] == nil {
                entries[deviceId] = Entry(fingerprints: Array(merged).sorted(), updatedAt: now)
                changed = true
            } else if var current = entries[deviceId] {
                current.updatedAt = now
                entries[deviceId] = current
            }
        }

        if changed {
            trimIfNeeded(maxEntries: 1024)
            return persist()
        }
        return true
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

    @discardableResult
    public func clear(deviceIds: [String]) -> Bool {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else { return false }

        var changed = false
        for deviceId in normalizedIds {
            if entries.removeValue(forKey: deviceId) != nil {
                changed = true
            }
        }

        guard changed else { return true }
        if entries.isEmpty {
#if DEBUG || SKYBRIDGE_TESTING
            if let persistenceResultOverrideForTesting, !persistenceResultOverrideForTesting {
                SkyBridgeLogger.p2p.warning(
                    "⚠️ Failed to remove derived bootstrap protocol identity cache: injected_failure"
                )
                return false
            }
#endif
            defaults.removeObject(forKey: Self.defaultsKey)
            guard defaults.data(forKey: Self.defaultsKey) == nil else {
                SkyBridgeLogger.p2p.warning(
                    "⚠️ Failed to verify derived bootstrap protocol identity cache removal"
                )
                return false
            }
            return true
        }
        return persist()
    }

#if DEBUG || SKYBRIDGE_TESTING
    func clearForTesting() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    func setPersistenceResultOverrideForTesting(_ result: Bool?) {
        persistenceResultOverrideForTesting = result
    }
#endif

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

    private func persist() -> Bool {
#if DEBUG || SKYBRIDGE_TESTING
        if let persistenceResultOverrideForTesting, !persistenceResultOverrideForTesting {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Failed to persist derived bootstrap protocol identity cache: injected_failure"
            )
            return false
        }
#endif
        do {
            let snapshot = Snapshot(entries: entries)
            let data = try JSONEncoder().encode(snapshot)
            defaults.set(data, forKey: Self.defaultsKey)
            guard defaults.data(forKey: Self.defaultsKey) == data else {
                SkyBridgeLogger.p2p.warning(
                    "⚠️ Failed to verify derived bootstrap protocol identity cache persistence"
                )
                return false
            }
            return true
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Failed to persist derived bootstrap protocol identity cache: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
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
