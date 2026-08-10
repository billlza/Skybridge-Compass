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

    struct Entry: Codable, Sendable, Equatable {
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
        var platform: String? = nil
        var osVersion: String? = nil
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

    struct AuthorityBoundPairingKEMMutationReceipt: Sendable {
        fileprivate struct TargetMutation: Sendable {
            let deviceId: String
            let before: Entry?
            let after: Entry
        }

        fileprivate let storeIdentifier: UUID
        fileprivate let authorityFingerprint: String
        fileprivate let targetMutations: [TargetMutation]
    }

    enum AuthorityBoundPairingKEMMutationError: Error, LocalizedError, Sendable, Equatable {
        case noTrustMaterialDeviceIds
        case noValidKEMPublicKeys
        case invalidProtocolFingerprint
        case capacityExceeded(limit: Int)

        var errorDescription: String? {
            switch self {
            case .noTrustMaterialDeviceIds:
                return "Authority-bound peer KEM mutation requires a stable trust-material device identifier"
            case .noValidKEMPublicKeys:
                return "Authority-bound peer KEM mutation requires at least one valid strict-PQC public key"
            case .invalidProtocolFingerprint:
                return "Authority-bound peer KEM mutation requires a canonical protocol identity fingerprint"
            case .capacityExceeded(let limit):
                return "Authority-bound peer KEM store capacity exceeded (limit: \(limit))"
            }
        }
    }

    private static let defaultsKey = "com.skybridge.p2p.bootstrap_kem_store.v1"
    private static let maximumEntryCount = 1024
    private let defaults: UserDefaults
    private let storeIdentifier = UUID()
    private var entries: [String: Entry]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.entries = Self.loadEntries(from: defaults)
    }

    /// Stores a `pairing_identity_exchange` bootstrap KEM.
    ///
    /// `verifiedProtocolFingerprint`, when supplied, is the lowercase canonical protocol identity
    /// fingerprint that the caller has already validated against the carried protocol public key
    /// bytes (i.e. `ProtocolIdentityBinding.computeFingerprint(...) == fingerprint`). It is recorded
    /// alongside the KEM so an authority-bound lookup (`authorityBoundPairingKEMPublicKeys`) can later
    /// return this material *only* when the consumer pins that exact fingerprint. The KEM itself is
    /// still authenticated end-to-end by the strict-PQC handshake transcript signature; the stored
    /// fingerprint simply lets the offerer scope the encapsulation target to the pinned identity.
    public func upsert(
        deviceIds: [String],
        kemPublicKeys: [KEMPublicKeyInfo],
        platform: String? = nil,
        osVersion: String? = nil,
        verifiedProtocolFingerprint: String? = nil
    ) {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else { return }

        let incoming = incomingKEMMap(kemPublicKeys, platform: platform, osVersion: osVersion)
        guard !incoming.isEmpty else { return }

        let normalizedFingerprint = Self.normalizedProtocolFingerprint(verifiedProtocolFingerprint)

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

            // Preserve any previously-recorded verified fingerprint when this call does not
            // carry one, so a later un-fingerprinted refresh of the same keys can't strip the pin.
            let resolvedFingerprint = normalizedFingerprint
                ?? (existingEntry?.source == "pairing_identity_exchange"
                    ? Self.normalizedProtocolFingerprint(existingEntry?.protocolIdentityFingerprint)
                    : nil)

            let fingerprintChanged = resolvedFingerprint
                != Self.normalizedProtocolFingerprint(existingEntry?.protocolIdentityFingerprint)

            if merged != existingKeys || entries[deviceId] == nil || fingerprintChanged {
                entries[deviceId] = Entry(
                    kemPublicKeys: merged,
                    updatedAt: now,
                    source: "pairing_identity_exchange",
                    protocolIdentityFingerprint: resolvedFingerprint,
                    platform: platform ?? existingEntry?.platform,
                    osVersion: osVersion ?? existingEntry?.osVersion
                )
                changed = true
            } else if var current = entries[deviceId] {
                current.updatedAt = now
                current.platform = platform ?? current.platform
                current.osVersion = osVersion ?? current.osVersion
                entries[deviceId] = current
            }
        }

        if changed {
            trimIfNeeded(maxEntries: Self.maximumEntryCount)
            persist()
        }
    }

    /// Atomically stores pairing bootstrap KEM material bound to one verified protocol authority.
    ///
    /// Unlike the legacy best-effort `upsert`, this transaction never evicts unrelated entries. It
    /// fails before mutation when adding its normalized targets would exceed the bounded store. The
    /// returned opaque receipt captures the exact before/after entry values for conditional rollback.
    func upsertAuthorityBoundPairingKEM(
        deviceIds: [String],
        kemPublicKeys: [KEMPublicKeyInfo],
        platform: String? = nil,
        osVersion: String? = nil,
        verifiedProtocolFingerprint: String
    ) throws -> AuthorityBoundPairingKEMMutationReceipt {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else {
            throw AuthorityBoundPairingKEMMutationError.noTrustMaterialDeviceIds
        }

        let incoming = incomingKEMMap(kemPublicKeys, platform: platform, osVersion: osVersion)
        guard !incoming.isEmpty else {
            throw AuthorityBoundPairingKEMMutationError.noValidKEMPublicKeys
        }

        guard let normalizedFingerprint = Self.normalizedProtocolFingerprint(
            verifiedProtocolFingerprint
        ) else {
            throw AuthorityBoundPairingKEMMutationError.invalidProtocolFingerprint
        }

        let observedAt = Date()
        var targetMutations: [AuthorityBoundPairingKEMMutationReceipt.TargetMutation] = []
        targetMutations.reserveCapacity(normalizedIds.count)

        for deviceId in normalizedIds {
            let existingEntry = entries[deviceId]
            if let existingEntry,
               existingEntry.source == "signed_lan_kem_refresh",
               existingEntry.expiresAt.map({ $0 > observedAt }) ?? true {
                continue
            }

            let existingKeys: [UInt16: Data]
            if existingEntry?.source == "signed_lan_kem_refresh",
               existingEntry?.expiresAt.map({ $0 <= observedAt }) == true {
                existingKeys = [:]
            } else {
                existingKeys = existingEntry?.kemPublicKeys ?? [:]
            }
            var merged = existingKeys
            for (suiteWireId, publicKey) in incoming {
                merged[suiteWireId] = publicKey
            }

            let after = Entry(
                kemPublicKeys: merged,
                updatedAt: Self.mutationTimestamp(
                    observedAt: observedAt,
                    after: existingEntry?.updatedAt
                ),
                source: "pairing_identity_exchange",
                protocolIdentityFingerprint: normalizedFingerprint,
                platform: platform ?? existingEntry?.platform,
                osVersion: osVersion ?? existingEntry?.osVersion
            )
            targetMutations.append(.init(
                deviceId: deviceId,
                before: existingEntry,
                after: after
            ))
        }

        let addedEntryCount = targetMutations.reduce(into: 0) { count, mutation in
            if mutation.before == nil {
                count += 1
            }
        }
        guard addedEntryCount <= Self.maximumEntryCount,
              entries.count <= Self.maximumEntryCount - addedEntryCount else {
            throw AuthorityBoundPairingKEMMutationError.capacityExceeded(
                limit: Self.maximumEntryCount
            )
        }

        for mutation in targetMutations {
            entries[mutation.deviceId] = mutation.after
        }
        if !targetMutations.isEmpty {
            persist()
        }

        return AuthorityBoundPairingKEMMutationReceipt(
            storeIdentifier: storeIdentifier,
            authorityFingerprint: normalizedFingerprint,
            targetMutations: targetMutations
        )
    }

    /// Restores an authority-bound mutation only while every target still equals the receipt's
    /// exact `after` value. A later write to any target supersedes the whole rollback transaction.
    @discardableResult
    func rollbackAuthorityBoundPairingKEMMutation(
        _ receipt: AuthorityBoundPairingKEMMutationReceipt
    ) -> Bool {
        guard receipt.storeIdentifier == storeIdentifier else { return false }
        guard receipt.targetMutations.allSatisfy({ mutation in
            entries[mutation.deviceId] == mutation.after
                && Self.normalizedProtocolFingerprint(mutation.after.protocolIdentityFingerprint)
                    == receipt.authorityFingerprint
        }) else {
            return false
        }

        for mutation in receipt.targetMutations {
            entries[mutation.deviceId] = mutation.before
        }
        if !receipt.targetMutations.isEmpty {
            if entries.isEmpty {
                defaults.removeObject(forKey: Self.defaultsKey)
            } else {
                persist()
            }
        }
        return true
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

        let validKeys = KEMPublicKeyInfo.normalizedValidKeys(
            validPayload.kemPublicKeys,
            platform: nil,
            osVersion: nil
        )
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
        trimIfNeeded(maxEntries: Self.maximumEntryCount)
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
            for (suiteWireId, publicKey) in Self.sanitizedKEMMap(
                entry.kemPublicKeys,
                platform: entry.platform,
                osVersion: entry.osVersion
            )
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

    /// Returns `pairing_identity_exchange` bootstrap KEM keyed strictly to a verified, pinned
    /// protocol identity.
    ///
    /// Security contract: a `pairing_identity_exchange` entry is only returned when its stored
    /// `protocolIdentityFingerprint` — recorded by `upsert(...,verifiedProtocolFingerprint:)` after the
    /// caller validated `computeFingerprint(bytes) == fingerprint` — is present in
    /// `pinnedProtocolFingerprints`. There is no blanket "return all" path: an empty pin set, an entry
    /// with no recorded fingerprint, or a fingerprint outside the pin set all yield nothing. This lets
    /// the strict-PQC offerer scope its KEM encapsulation target to the pinned authority while the
    /// handshake transcript signature still provides end-to-end authentication of the chosen KEM.
    public func authorityBoundPairingKEMPublicKeys(
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
                  entry.source == "pairing_identity_exchange",
                  let storedFingerprint = Self.normalizedProtocolFingerprint(entry.protocolIdentityFingerprint),
                  normalizedPins.contains(storedFingerprint) else {
                continue
            }
            if let expiresAt = entry.expiresAt, expiresAt <= Date() { continue }
            for (suiteWireId, publicKey) in Self.sanitizedKEMMap(
                entry.kemPublicKeys,
                platform: entry.platform,
                osVersion: entry.osVersion
            ) {
                let candidateKey = SelectedKey(
                    publicKey: publicKey,
                    updatedAt: entry.updatedAt,
                    isSignedRefresh: false,
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
            for (suiteWireId, publicKey) in Self.sanitizedKEMMap(
                entry.kemPublicKeys,
                platform: entry.platform,
                osVersion: entry.osVersion
            ) {
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

#if DEBUG || SKYBRIDGE_TESTING
    func clearForTesting() {
        entries.removeAll()
        defaults.removeObject(forKey: Self.defaultsKey)
    }
#endif

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

    private func incomingKEMMap(
        _ kemPublicKeys: [KEMPublicKeyInfo],
        platform: String?,
        osVersion: String?
    ) -> [UInt16: Data] {
        var result: [UInt16: Data] = [:]
        for key in KEMPublicKeyInfo.normalizedValidKeys(
            kemPublicKeys,
            platform: platform,
            osVersion: osVersion
        ) {
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

    private static func mutationTimestamp(observedAt: Date, after previous: Date?) -> Date {
        guard let previous, observedAt <= previous else { return observedAt }
        return Date(
            timeIntervalSinceReferenceDate: previous.timeIntervalSinceReferenceDate.nextUp
        )
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
        sanitized.kemPublicKeys = sanitizedKEMMap(
            entry.kemPublicKeys,
            platform: entry.platform,
            osVersion: entry.osVersion
        )
        guard !sanitized.kemPublicKeys.isEmpty else { return nil }
        if let signedSuiteWireIds = sanitized.signedSuiteWireIds {
            sanitized.signedSuiteWireIds = signedSuiteWireIds
                .filter { sanitized.kemPublicKeys[$0] != nil }
                .sorted()
        }
        return sanitized
    }

    private static func sanitizedKEMMap(
        _ keys: [UInt16: Data],
        platform: String? = nil,
        osVersion: String? = nil
    ) -> [UInt16: Data] {
        let keyInfos = keys.map { KEMPublicKeyInfo(suiteWireId: $0.key, publicKey: $0.value) }
        return Dictionary(
            uniqueKeysWithValues: KEMPublicKeyInfo.normalizedValidKeys(
                keyInfos,
                platform: platform,
                osVersion: osVersion
            ).map {
                ($0.suiteWireId, $0.publicKey)
            }
        )
    }
}
