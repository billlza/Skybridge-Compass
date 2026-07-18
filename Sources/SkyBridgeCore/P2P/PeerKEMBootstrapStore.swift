import Foundation
import CryptoKit

@available(macOS 14.0, iOS 17.0, *)
public actor PeerKEMBootstrapStore {
    public static let shared = PeerKEMBootstrapStore()

    public enum PairingWriteError: Error, LocalizedError, Sendable, Equatable {
        case invalidIdentifiers
        case invalidKEMPayload
        case generationOverflow

        public var errorDescription: String? {
            switch self {
            case .invalidIdentifiers:
                return "Pairing KEM write has no stable device identifiers"
            case .invalidKEMPayload:
                return "Pairing KEM write contains no valid KEM public keys"
            case .generationOverflow:
                return "Pairing KEM write generation exhausted"
            }
        }
    }

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
        var platform: String? = nil
        var osVersion: String? = nil
        /// Local ordering lease for pairing writes. This is deliberately
        /// separate from the signed remote KEM refresh generation.
        var pairingWriteGeneration: UInt64? = nil
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
    private var pairingWriteReservationByDeviceId: [String: UInt64] = [:]
    /// Monotonic per-identity admission watermark. Unlike the one-shot
    /// reservation map, this survives a failed successor attempt for as long
    /// as an older entry remains, so an older post-commit receipt cannot become
    /// current again after the successor releases its reservation (ABA).
    private var latestAdmittedPairingWriteGenerationByDeviceId: [String: UInt64]
    private var maximumIssuedPairingWriteGeneration: UInt64

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let loadedEntries = Self.loadEntries(from: defaults)
        self.entries = loadedEntries
        self.latestAdmittedPairingWriteGenerationByDeviceId = loadedEntries.reduce(into: [:]) { result, element in
            if let generation = element.value.pairingWriteGeneration {
                result[element.key] = generation
            }
        }
        self.maximumIssuedPairingWriteGeneration = loadedEntries.values
            .compactMap(\.pairingWriteGeneration)
            .max() ?? 0
    }

#if DEBUG
    init(defaultsSuiteNameForTesting suiteName: String) {
        self.init(defaults: Self.requiredDefaultsSuiteForTesting(named: suiteName))
    }

    private nonisolated static func requiredDefaultsSuiteForTesting(
        named suiteName: String
    ) -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Unable to create isolated UserDefaults suite")
        }
        return defaults
    }
#endif

    /// Reserves a one-shot generation before any pairing operation awaits.
    /// A later reservation immediately invalidates the older operation even
    /// when the replacement has not committed its KEM payload yet.
    public func reservePairingWriteGeneration(deviceIds: [String]) throws -> UInt64 {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else {
            throw PairingWriteError.invalidIdentifiers
        }

        let maximumPersistedGeneration = entries.values
            .compactMap(\.pairingWriteGeneration)
            .max() ?? 0
        let maximumReservedGeneration = pairingWriteReservationByDeviceId.values.max() ?? 0
        let maximumGeneration = max(
            maximumIssuedPairingWriteGeneration,
            max(maximumPersistedGeneration, maximumReservedGeneration)
        )
        guard maximumGeneration < UInt64.max else {
            throw PairingWriteError.generationOverflow
        }
        let generation = maximumGeneration + 1
        maximumIssuedPairingWriteGeneration = generation
        for deviceId in normalizedIds {
            pairingWriteReservationByDeviceId[deviceId] = generation
            latestAdmittedPairingWriteGenerationByDeviceId[deviceId] = generation
        }
        return generation
    }

    /// Returns true only while every identifier in the original reservation
    /// still belongs to the same generation. Pairing authority persistence uses
    /// this immediately before its durable write so a newer connection cannot
    /// commit under an older KEM admission lease.
    func isCurrentPairingWriteReservation(
        deviceIds: [String],
        matchingGeneration: UInt64
    ) -> Bool {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else { return false }
        return normalizedIds.allSatisfy {
            pairingWriteReservationByDeviceId[$0] == matchingGeneration
                && latestAdmittedPairingWriteGenerationByDeviceId[$0] == matchingGeneration
        }
    }

    /// Validates the post-commit ownership epoch. A newer reservation makes the
    /// older committed payload stale even before the replacement persists.
    func isCurrentPairingWriteCommit(
        deviceIds: [String],
        matchingGeneration: UInt64,
        matchingProtocolFingerprint: String
    ) -> Bool {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty,
              let normalizedFingerprint = Self.normalizedProtocolFingerprint(
                matchingProtocolFingerprint
              ) else {
            return false
        }
        let now = Date()
        return normalizedIds.allSatisfy { deviceId in
            guard latestAdmittedPairingWriteGenerationByDeviceId[deviceId]
                    == matchingGeneration else {
                return false
            }
            if let reservedGeneration = pairingWriteReservationByDeviceId[deviceId],
               reservedGeneration != matchingGeneration {
                return false
            }
            guard let entry = entries[deviceId] else { return false }
            if entry.source == "pairing_identity_exchange" {
                return entry.pairingWriteGeneration == matchingGeneration
                    && Self.normalizedProtocolFingerprint(entry.protocolIdentityFingerprint)
                        == normalizedFingerprint
            }
            if entry.source == "signed_lan_kem_refresh" {
                guard entry.expiresAt.map({ $0 > now }) ?? true else { return false }
                return Self.entry(entry, isBoundToAny: [normalizedFingerprint])
            }
            return false
        }
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
        do {
            _ = try upsertPairingKEM(
                deviceIds: deviceIds,
                kemPublicKeys: kemPublicKeys,
                platform: platform,
                osVersion: osVersion,
                verifiedProtocolFingerprint: verifiedProtocolFingerprint,
                pairingWriteGeneration: nil
            )
        } catch {
            SkyBridgeLogger.p2p.error(
                "Failed to persist pairing KEM bootstrap cache: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Commits a reserved pairing payload as an authoritative replacement.
    /// Returns `false` when a newer reservation has superseded this operation.
    @discardableResult
    public func upsert(
        deviceIds: [String],
        kemPublicKeys: [KEMPublicKeyInfo],
        platform: String? = nil,
        osVersion: String? = nil,
        verifiedProtocolFingerprint: String? = nil,
        pairingWriteGeneration: UInt64
    ) throws -> Bool {
        try upsertPairingKEM(
            deviceIds: deviceIds,
            kemPublicKeys: kemPublicKeys,
            platform: platform,
            osVersion: osVersion,
            verifiedProtocolFingerprint: verifiedProtocolFingerprint,
            pairingWriteGeneration: pairingWriteGeneration
        )
    }

    private func upsertPairingKEM(
        deviceIds: [String],
        kemPublicKeys: [KEMPublicKeyInfo],
        platform: String?,
        osVersion: String?,
        verifiedProtocolFingerprint: String?,
        pairingWriteGeneration: UInt64?
    ) throws -> Bool {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else {
            if pairingWriteGeneration != nil {
                throw PairingWriteError.invalidIdentifiers
            }
            return true
        }

        // A reservation is one-shot: every terminal outcome (success,
        // superseded write, invalid payload, or persistence failure) releases
        // only the IDs still owned by this generation. This keeps
        // partial-overlap replacements bounded without allowing an older
        // operation to erase a successor's reservation.
        defer {
            if let pairingWriteGeneration {
                for deviceId in normalizedIds
                where pairingWriteReservationByDeviceId[deviceId] == pairingWriteGeneration {
                    pairingWriteReservationByDeviceId.removeValue(forKey: deviceId)
                }
                prunePairingAdmissionWatermarksWithoutEntryOrReservation()
            }
        }

        let incoming = incomingKEMMap(kemPublicKeys, platform: platform, osVersion: osVersion)
        guard !incoming.isEmpty else {
            if pairingWriteGeneration != nil {
                throw PairingWriteError.invalidKEMPayload
            }
            return true
        }

        if let pairingWriteGeneration,
           normalizedIds.contains(where: {
               pairingWriteReservationByDeviceId[$0] != pairingWriteGeneration
           }) {
            return false
        }

        let normalizedFingerprint = Self.normalizedProtocolFingerprint(verifiedProtocolFingerprint)

        let now = Date()
        var updatedEntries = entries
        var changed = false

        for deviceId in normalizedIds {
            if pairingWriteGeneration == nil,
               (pairingWriteReservationByDeviceId[deviceId] != nil
                    || updatedEntries[deviceId]?.pairingWriteGeneration != nil) {
                continue
            }
            if let existing = updatedEntries[deviceId],
               existing.source == "signed_lan_kem_refresh",
               existing.expiresAt.map({ $0 > now }) ?? true {
                continue
            }
            let existingEntry = updatedEntries[deviceId]

            if let pairingWriteGeneration {
                let replacement = Entry(
                    kemPublicKeys: incoming,
                    updatedAt: now,
                    source: "pairing_identity_exchange",
                    protocolIdentityFingerprint: normalizedFingerprint,
                    platform: platform,
                    osVersion: osVersion,
                    pairingWriteGeneration: pairingWriteGeneration
                )
                if existingEntry?.pairingWriteGeneration != pairingWriteGeneration
                    || existingEntry?.kemPublicKeys != incoming
                    || existingEntry?.protocolIdentityFingerprint != normalizedFingerprint
                    || existingEntry?.platform != platform
                    || existingEntry?.osVersion != osVersion {
                    updatedEntries[deviceId] = replacement
                    changed = true
                }
                continue
            }

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

            if merged != existingKeys || updatedEntries[deviceId] == nil || fingerprintChanged {
                updatedEntries[deviceId] = Entry(
                    kemPublicKeys: merged,
                    updatedAt: now,
                    source: "pairing_identity_exchange",
                    protocolIdentityFingerprint: resolvedFingerprint,
                    platform: platform ?? existingEntry?.platform,
                    osVersion: osVersion ?? existingEntry?.osVersion
                )
                changed = true
            } else if var current = updatedEntries[deviceId] {
                current.updatedAt = now
                current.platform = platform ?? current.platform
                current.osVersion = osVersion ?? current.osVersion
                updatedEntries[deviceId] = current
            }
        }

        if changed {
            Self.trim(&updatedEntries, maxEntries: 1024)
            try persist(updatedEntries)
            entries = updatedEntries
            prunePairingAdmissionWatermarksWithoutEntryOrReservation()
        } else if pairingWriteGeneration == nil {
            entries = updatedEntries
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
        do {
            try clearPersisting(deviceIds: deviceIds)
        } catch {
            SkyBridgeLogger.p2p.error(
                "Failed to clear bootstrap KEM cache: \(error.localizedDescription, privacy: .public)"
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

        if changed {
            try persist(updatedEntries)
            entries = updatedEntries
        }
        for deviceId in normalizedIds {
            pairingWriteReservationByDeviceId.removeValue(forKey: deviceId)
        }
        prunePairingAdmissionWatermarksWithoutEntryOrReservation()
    }

    public func clearPairingIdentityExchangeEntries(deviceIds: [String]) {
        do {
            try clearPairingIdentityExchangeEntriesPersisting(deviceIds: deviceIds)
        } catch {
            SkyBridgeLogger.p2p.error(
                "Failed to clear pairing KEM bootstrap cache: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func clearPairingIdentityExchangeEntriesPersisting(deviceIds: [String]) throws {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else { return }

        var updatedEntries = entries
        var changed = false
        for deviceId in normalizedIds {
            guard updatedEntries[deviceId]?.source == "pairing_identity_exchange" else {
                continue
            }
            updatedEntries.removeValue(forKey: deviceId)
            changed = true
        }

        if changed {
            try persist(updatedEntries)
            entries = updatedEntries
        }
        for deviceId in normalizedIds {
            pairingWriteReservationByDeviceId.removeValue(forKey: deviceId)
        }
        prunePairingAdmissionWatermarksWithoutEntryOrReservation()
    }

    /// Cancels or rolls back exactly one reserved pairing write. A stale
    /// operation cannot erase a replacement entry or its reservation.
    @discardableResult
    public func rollbackPairingIdentityExchangeEntries(
        deviceIds: [String],
        matchingWriteGeneration: UInt64
    ) async throws -> Bool {
        let normalizedIds = trustMaterialIds(deviceIds)
        guard !normalizedIds.isEmpty else {
            throw PairingWriteError.invalidIdentifiers
        }

        var updatedEntries = entries
        var removedEntry = false
        for deviceId in normalizedIds {
            guard updatedEntries[deviceId]?.source == "pairing_identity_exchange",
                  updatedEntries[deviceId]?.pairingWriteGeneration == matchingWriteGeneration else {
                continue
            }
            updatedEntries.removeValue(forKey: deviceId)
            removedEntry = true
        }

        if removedEntry {
            try persist(updatedEntries)
            entries = updatedEntries
        }
        var removedReservation = false
        for deviceId in normalizedIds
        where pairingWriteReservationByDeviceId[deviceId] == matchingWriteGeneration {
            pairingWriteReservationByDeviceId.removeValue(forKey: deviceId)
            removedReservation = true
        }
        prunePairingAdmissionWatermarksWithoutEntryOrReservation()
        return removedEntry || removedReservation
    }

    func clearForTesting() {
        entries.removeAll()
        pairingWriteReservationByDeviceId.removeAll()
        latestAdmittedPairingWriteGenerationByDeviceId.removeAll()
        maximumIssuedPairingWriteGeneration = 0
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
        Self.trim(&entries, maxEntries: maxEntries)
        prunePairingAdmissionWatermarksWithoutEntryOrReservation()
    }

    private func prunePairingAdmissionWatermarksWithoutEntryOrReservation() {
        latestAdmittedPairingWriteGenerationByDeviceId =
            latestAdmittedPairingWriteGenerationByDeviceId.filter { deviceId, _ in
                entries[deviceId] != nil
                    || pairingWriteReservationByDeviceId[deviceId] != nil
            }
    }

    private static func trim(_ entries: inout [String: Entry], maxEntries: Int) {
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
            try persist(entries)
        } catch {
            SkyBridgeLogger.p2p.warning(
                "⚠️ Failed to persist bootstrap KEM cache: \(error.localizedDescription, privacy: .public)"
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
