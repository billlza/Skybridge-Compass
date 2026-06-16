import Foundation
import CryptoKit

@available(macOS 14.0, iOS 17.0, *)
public actor PeerKEMBootstrapStore {
    public static let shared = PeerKEMBootstrapStore()

    public enum SignedRefreshImportError: Error, LocalizedError, Sendable, Equatable {
        case signatureVerificationFailed
        case signatureVerificationError(String)

        public var errorDescription: String? {
            switch self {
            case .signatureVerificationFailed:
                return "SKR-1 signature verification failed at peer KEM bootstrap import"
            case .signatureVerificationError(let detail):
                return "SKR-1 signature verification error at peer KEM bootstrap import: \(detail)"
            }
        }
    }

    private struct Entry: Codable, Sendable {
        var kemPublicKeys: [UInt16: Data]
        var updatedAt: Date
        var source: String? = nil
        var keyId: String? = nil
        var generation: UInt64? = nil
        var expiresAt: Date? = nil
        var protocolIdentityFingerprint: String? = nil
        var signingFingerprint: String? = nil
        var payloadHashHex: String? = nil
        var signedSuiteWireIds: [UInt16]? = nil
        var signedRefreshDeviceId: String? = nil
    }

    private struct Snapshot: Codable, Sendable {
        var entries: [String: Entry]
    }

    private struct SelectedKey: Sendable {
        let publicKey: Data
        let updatedAt: Date
        let isSignedRefresh: Bool
        let lookupIndex: Int
    }

    public struct SignedRefreshEvidence: Sendable, Equatable {
        public let deviceId: String
        public let suiteWireIds: [UInt16]
        public let source: String?
        public let keyId: String?
        public let generation: UInt64?
        public let expiresAt: Date?
        public let protocolIdentityFingerprint: String?
        public let signingFingerprint: String?
        public let payloadHashHex: String?
        public let updatedAt: Date
    }

    private static let defaultsKey = "com.skybridge.p2p.bootstrap_kem_store.v1"
    private let defaults: UserDefaults
    private var entries: [String: Entry]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.loadEntries(from: defaults)
    }

    public func upsert(deviceIds: [String], kemPublicKeys: [KEMPublicKeyInfo]) {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else { return }

        let incoming = incomingKEMMap(kemPublicKeys)
        guard !incoming.isEmpty else { return }

        let now = Date()
        var changed = false

        for deviceId in normalizedIds {
            if let existing = entries[deviceId],
               existing.source == "signed_lan_kem_refresh",
               existing.expiresAt.map({ $0 > now }) ?? true {
                continue
            }
            let existingEntry = entries[deviceId]
            let existingKeys: [UInt16: Data]
            if existingEntry?.source == "signed_lan_kem_refresh",
               existingEntry?.expiresAt.map({ $0 <= now }) == true {
                existingKeys = [:]
            } else {
                existingKeys = existingEntry?.kemPublicKeys ?? [:]
            }
            var merged = existingKeys
            for (suiteWireId, publicKey) in incoming {
                merged[suiteWireId] = publicKey
            }

            if merged != existingKeys || entries[deviceId] == nil {
                entries[deviceId] = Entry(
                    kemPublicKeys: merged,
                    updatedAt: now,
                    source: "pairing_identity_exchange"
                )
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

    public func upsertSignedKEMRefresh(
        deviceIds: [String],
        payload: AppMessage.SignedKEMRefreshPayload,
        request: AppMessage.KEMRefreshRequestPayload,
        pinnedProtocolFingerprints: Set<String>,
        minimumGeneration: UInt64?
    ) async throws {
        let validPayload = try payload.validatedForStrictPQCImport(
            request: request,
            pinnedProtocolFingerprints: pinnedProtocolFingerprints,
            minimumGeneration: minimumGeneration
        )
        guard let algorithm = ProtocolSigningAlgorithm(rawValue: validPayload.protocolSigningAlgorithm) else {
            throw AppMessage.KEMRefreshValidationError.invalidSignatureAlgorithm
        }
        let signatureProvider = ProtocolSignatureProviderSelector.select(for: algorithm)
        let verified: Bool
        do {
            verified = try await signatureProvider.verify(
                validPayload.signaturePreimage,
                signature: validPayload.signature,
                publicKey: validPayload.protocolIdentityPublicKey
            )
        } catch {
            throw SignedRefreshImportError.signatureVerificationError(error.localizedDescription)
        }
        guard verified else {
            throw SignedRefreshImportError.signatureVerificationFailed
        }

        let validKeys = KEMPublicKeyInfo.normalizedValidKeys(validPayload.kemPublicKeys)
        guard !validKeys.isEmpty else { return }

        let identifiers = [validPayload.deviceId] + validPayload.aliases + deviceIds
        let candidates = trustMaterialIds(identifiers)
        guard !candidates.isEmpty else { return }

        let keyDict = Dictionary(uniqueKeysWithValues: validKeys.map { ($0.suiteWireId, $0.publicKey) })
        let payloadHash = Self.sha256Hex(validPayload.signaturePreimage)
        let observedAt = Date()
        for candidate in candidates {
            entries[candidate] = Entry(
                kemPublicKeys: keyDict,
                updatedAt: observedAt,
                source: "signed_lan_kem_refresh",
                keyId: validPayload.keyId,
                generation: validPayload.generation,
                expiresAt: validPayload.expiresAt,
                protocolIdentityFingerprint: validPayload.protocolIdentityFingerprint,
                signingFingerprint: validPayload.protocolIdentityFingerprint,
                payloadHashHex: payloadHash,
                signedSuiteWireIds: validKeys.map(\.suiteWireId).sorted(),
                signedRefreshDeviceId: validPayload.deviceId
            )
        }
        trimIfNeeded(maxEntries: 1024)
        persist()
    }

    public func mergedKEMPublicKeys(forCandidates candidates: [String]) -> [UInt16: Data] {
        Dictionary(
            uniqueKeysWithValues: selectKEMPublicKeys(forCandidates: candidates).map { suiteWireId, selected in
                (suiteWireId, selected.publicKey)
            }
        )
    }

    public func signedRefreshKEMPublicKeys(
        forCandidates candidates: [String],
        pinnedProtocolFingerprints: Set<String>
    ) -> [UInt16: Data] {
        let normalizedPins = Set(pinnedProtocolFingerprints.compactMap(Self.normalizedProtocolFingerprint))
        guard !normalizedPins.isEmpty else { return [:] }
        let normalizedCandidates = trustMaterialIds(candidates)
        guard !normalizedCandidates.isEmpty else { return [:] }

        var selected: [UInt16: SelectedKey] = [:]
        for (index, candidate) in normalizedCandidates.enumerated() {
            guard let entry = entries[candidate],
                  entry.source == "signed_lan_kem_refresh",
                  Self.entry(entry, isBoundToAny: normalizedPins) else {
                continue
            }
            if let expiresAt = entry.expiresAt, expiresAt <= Date() { continue }
            let signedSuiteWireIds = Set(entry.signedSuiteWireIds ?? entry.kemPublicKeys.keys.sorted())
            for (suiteWireId, publicKey) in Self.sanitizedKEMMap(entry.kemPublicKeys)
            where signedSuiteWireIds.contains(suiteWireId) {
                let candidateKey = SelectedKey(
                    publicKey: publicKey,
                    updatedAt: entry.updatedAt,
                    isSignedRefresh: true,
                    lookupIndex: index
                )
                if Self.shouldPrefer(candidateKey, over: selected[suiteWireId]) {
                    selected[suiteWireId] = candidateKey
                }
            }
        }

        return Dictionary(uniqueKeysWithValues: selected.map { ($0.key, $0.value.publicKey) })
    }

    private func selectKEMPublicKeys(forCandidates candidates: [String]) -> [UInt16: SelectedKey] {
        let normalizedCandidates = trustMaterialIds(candidates)
        guard !normalizedCandidates.isEmpty else { return [:] }

        var selected: [UInt16: SelectedKey] = [:]
        for (index, candidate) in normalizedCandidates.enumerated() {
            guard let entry = entries[candidate] else { continue }
            if let expiresAt = entry.expiresAt, expiresAt <= Date() { continue }
            let fallbackSignedSuiteWireIds: [UInt16] = entry.source == "signed_lan_kem_refresh"
                ? Array(entry.kemPublicKeys.keys)
                : []
            let signedSuiteWireIds = Set(entry.signedSuiteWireIds ?? fallbackSignedSuiteWireIds)
            for (suiteWireId, publicKey) in Self.sanitizedKEMMap(entry.kemPublicKeys) {
                let candidateKey = SelectedKey(
                    publicKey: publicKey,
                    updatedAt: entry.updatedAt,
                    isSignedRefresh: entry.source == "signed_lan_kem_refresh" && signedSuiteWireIds.contains(suiteWireId),
                    lookupIndex: index
                )
                if Self.shouldPrefer(candidateKey, over: selected[suiteWireId]) {
                    selected[suiteWireId] = candidateKey
                }
            }
        }
        return selected
    }

    public func availableSuiteWireIds(forCandidates candidates: [String]) -> [UInt16] {
        Array(mergedKEMPublicKeys(forCandidates: candidates).keys).sorted()
    }

    public func maximumKEMGeneration(forCandidates candidates: [String]) -> UInt64? {
        var maximum: UInt64?
        for candidate in trustMaterialIds(candidates) {
            guard let generation = entries[candidate]?.generation else { continue }
            maximum = max(maximum ?? generation, generation)
        }
        return maximum
    }

    public func signedRefreshEvidence(forCandidates candidates: [String]) -> SignedRefreshEvidence? {
        var selected: SignedRefreshEvidence?
        for candidate in trustMaterialIds(candidates) {
            guard let entry = entries[candidate],
                  entry.source == "signed_lan_kem_refresh" else {
                continue
            }
            if let expiresAt = entry.expiresAt, expiresAt <= Date() { continue }
            let evidence = SignedRefreshEvidence(
                deviceId: entry.signedRefreshDeviceId ?? candidate,
                suiteWireIds: entry.signedSuiteWireIds ?? entry.kemPublicKeys.keys.sorted(),
                source: entry.source,
                keyId: entry.keyId,
                generation: entry.generation,
                expiresAt: entry.expiresAt,
                protocolIdentityFingerprint: entry.protocolIdentityFingerprint,
                signingFingerprint: entry.signingFingerprint ?? entry.protocolIdentityFingerprint,
                payloadHashHex: entry.payloadHashHex,
                updatedAt: entry.updatedAt
            )
            if selected.map({ evidence.updatedAt > $0.updatedAt }) ?? true {
                selected = evidence
            }
        }
        return selected
    }

    public func clear(deviceIds: [String]) {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else { return }

        var changed = false
        for deviceId in normalizedIds {
            if entries.removeValue(forKey: deviceId) != nil {
                changed = true
            }
        }

        guard changed else { return }
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            persist()
        }
    }

    public func clearPairingIdentityExchangeEntries(deviceIds: [String]) {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else { return }

        var changed = false
        for deviceId in normalizedIds {
            guard entries[deviceId]?.source == "pairing_identity_exchange" else {
                continue
            }
            entries.removeValue(forKey: deviceId)
            changed = true
        }

        guard changed else { return }
        if entries.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            persist()
        }
    }

    func clearForTesting() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    private func lookupCandidates(forAny identifiers: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for identifier in identifiers {
            for candidate in PeerTrustLookup.lookupCandidates(for: identifier)
            where !PeerTrustLookup.isEndpointAlias(candidate) && seen.insert(candidate).inserted {
                result.append(candidate)
            }
        }
        return result
    }

    private func trustMaterialIds(_ rawIds: [String]) -> [String] {
        lookupCandidates(forAny: rawIds)
    }

    private func incomingKEMMap(_ kemPublicKeys: [KEMPublicKeyInfo]) -> [UInt16: Data] {
        var result: [UInt16: Data] = [:]
        for key in KEMPublicKeyInfo.normalizedValidKeys(kemPublicKeys) {
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

    private static func shouldPrefer(_ candidate: SelectedKey, over existing: SelectedKey?) -> Bool {
        guard let existing else { return true }
        if candidate.isSignedRefresh != existing.isSignedRefresh {
            return candidate.isSignedRefresh
        }
        if candidate.lookupIndex != existing.lookupIndex {
            return candidate.lookupIndex < existing.lookupIndex
        }
        return candidate.updatedAt > existing.updatedAt
    }

    private static func entry(_ entry: Entry, isBoundToAny normalizedPins: Set<String>) -> Bool {
        [
            normalizedProtocolFingerprint(entry.signingFingerprint),
            normalizedProtocolFingerprint(entry.protocolIdentityFingerprint)
        ]
        .compactMap { $0 }
        .contains { normalizedPins.contains($0) }
    }

    private static func normalizedProtocolFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
            return snapshot.entries.compactMapValues(Self.sanitizedEntry)
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Failed to load bootstrap KEM cache: \(error.localizedDescription, privacy: .public)"
            )
            return [:]
        }
    }

    private static func sanitizedEntry(_ entry: Entry) -> Entry? {
        var sanitized = entry
        sanitized.kemPublicKeys = sanitizedKEMMap(entry.kemPublicKeys)
        guard !sanitized.kemPublicKeys.isEmpty else { return nil }
        if let signedSuiteWireIds = sanitized.signedSuiteWireIds {
            sanitized.signedSuiteWireIds = signedSuiteWireIds
                .filter { sanitized.kemPublicKeys[$0] != nil }
                .sorted()
        }
        return sanitized
    }

    private static func sanitizedKEMMap(_ keys: [UInt16: Data]) -> [UInt16: Data] {
        let keyInfos = keys.map { KEMPublicKeyInfo(suiteWireId: $0.key, publicKey: $0.value) }
        return Dictionary(
            uniqueKeysWithValues: KEMPublicKeyInfo.normalizedValidKeys(keyInfos).map {
                ($0.suiteWireId, $0.publicKey)
            }
        )
    }
}
