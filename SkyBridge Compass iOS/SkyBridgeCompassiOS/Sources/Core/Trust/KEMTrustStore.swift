import Foundation
import CryptoKit

/// Stores peer KEM identity public keys by deviceId.
/// This is the missing prerequisite for negotiating PQC suites (initiator needs peer KEM public key).
@available(iOS 17.0, *)
public actor KEMTrustStore {
    public static let shared = KEMTrustStore()
    private static let maximumStoredPeerAliases = 1_024
    private static let maximumAuthorityBoundBootstrapsPerPeer = 4

    public enum SignedRefreshImportError: Error, LocalizedError, Sendable, Equatable {
        case signatureVerificationFailed
        case signatureVerificationError(String)

        public var errorDescription: String? {
            switch self {
            case .signatureVerificationFailed:
                return "SKR-1 signature verification failed at KEM trust store import"
            case .signatureVerificationError(let detail):
                return "SKR-1 signature verification error at KEM trust store import: \(detail)"
            }
        }
    }

    public enum PersistenceError: Error, LocalizedError, Sendable, Equatable {
        case persistenceUnavailable(String)
        case authorityTransactionQuarantined
        case decodingFailed(String)
        case encodingFailed(String)
        case writeVerificationFailed
        case concurrentModification

        public var errorDescription: String? {
            switch self {
            case .persistenceUnavailable(let reason):
                return "KEM trust persistence is unavailable: \(reason)"
            case .authorityTransactionQuarantined:
                return "KEM trust is quarantined by an incomplete pairing identity transaction"
            case .decodingFailed(let reason):
                return "KEM trust store decoding failed: \(reason)"
            case .encodingFailed(let reason):
                return "KEM trust store encoding failed: \(reason)"
            case .writeVerificationFailed:
                return "KEM trust store write could not be verified"
            case .concurrentModification:
                return "KEM trust state changed before rollback"
            }
        }
    }

    fileprivate struct StoredPeer: Codable, Sendable, Equatable {
        struct AuthorityBoundBootstrap: Codable, Sendable, Equatable {
            var keys: [UInt16: Data]
            var updatedAt: Date
        }

        var keys: [UInt16: Data] // suiteWireId -> publicKey
        var updatedAt: Date
        var source: String? = nil
        var keyId: String? = nil
        var generation: UInt64? = nil
        var expiresAt: Date? = nil
        var protocolIdentityFingerprint: String? = nil
        var signingFingerprint: String? = nil
        var payloadHashHex: String? = nil
        var requestHashHex: String? = nil
        var recoveryEvidenceReference: String? = nil
        var signedSuiteWireIds: [UInt16]? = nil
        var signedRefreshDeviceId: String? = nil
        var authorityBoundBootstraps: [String: AuthorityBoundBootstrap]? = nil
    }

    fileprivate struct AuthorityBoundEntryMutation: Codable, Sendable, Equatable {
        let deviceId: String
        let previous: StoredPeer?
        let committed: StoredPeer?
        /// When present, rollback is a field-level CAS for this authenticated
        /// bootstrap slot. A concurrent update to another fingerprint on the
        /// same device must survive compensation.
        let bootstrapFingerprint: String?
    }

    struct AuthorityBoundMutationReceipt: Codable, Sendable, Equatable {
        fileprivate let entries: [AuthorityBoundEntryMutation]
    }

    /// Opaque, exact serialization of the complete store. A full snapshot is
    /// intentional: authority-bound insertion may evict an unrelated alias at
    /// the bounded-capacity edge, so a per-device snapshot cannot recover the
    /// transaction without losing data.
    struct AuthorityBoundSnapshot: Codable, Sendable, Equatable {
        fileprivate let encodedCache: Data
    }

    struct PreparedAuthorityBoundMutation: Sendable {
        let before: AuthorityBoundSnapshot
        let after: AuthorityBoundSnapshot
        let receipt: AuthorityBoundMutationReceipt
    }

    private struct SelectedKey: Sendable {
        let publicKey: Data
        let updatedAt: Date
        let isCanonical: Bool
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
        public let requestHashHex: String?
        public let recoveryEvidenceReference: String?
        public let updatedAt: Date

        public init(
            deviceId: String,
            suiteWireIds: [UInt16],
            source: String?,
            keyId: String?,
            generation: UInt64?,
            expiresAt: Date?,
            protocolIdentityFingerprint: String?,
            signingFingerprint: String?,
            payloadHashHex: String?,
            requestHashHex: String? = nil,
            recoveryEvidenceReference: String? = nil,
            updatedAt: Date
        ) {
            self.deviceId = deviceId
            self.suiteWireIds = suiteWireIds
            self.source = source
            self.keyId = keyId
            self.generation = generation
            self.expiresAt = expiresAt
            self.protocolIdentityFingerprint = protocolIdentityFingerprint
            self.signingFingerprint = signingFingerprint
            self.payloadHashHex = payloadHashHex
            self.requestHashHex = requestHashHex
            self.recoveryEvidenceReference = recoveryEvidenceReference
            self.updatedAt = updatedAt
        }
    }

    private let storageKey: String
    private let userDefaults: UserDefaults
    private let authorityJournalExists: @Sendable () -> Bool
    private let pairingAcceptanceJournalExists: @Sendable () -> Bool
    private var cache: [String: StoredPeer] = [:] // deviceId -> StoredPeer
    private var persistenceFailureReason: String?

    init(
        storageKey: String = "kem_trust_store.v1",
        userDefaults: UserDefaults = .standard,
        authorityJournalExists: @escaping @Sendable () -> Bool = {
            AuthorityBoundPairingIdentityJournalStore.defaultJournalExists()
        },
        pairingAcceptanceJournalExists: @escaping @Sendable () -> Bool = {
            PairingAcceptanceJournalStore.defaultJournalExists()
        }
    ) {
        self.storageKey = storageKey
        self.userDefaults = userDefaults
        self.authorityJournalExists = authorityJournalExists
        self.pairingAcceptanceJournalExists = pairingAcceptanceJournalExists
        do {
            cache = try Self.loadCache(storageKey: storageKey, userDefaults: userDefaults)
        } catch {
            cache = [:]
            persistenceFailureReason = error.localizedDescription
        }
    }

    public func upsert(deviceId: String, kemPublicKeys: [KEMPublicKeyInfo]) {
        guard !isAuthorityJournalQuarantined else { return }
        let previousCache = cache
        let candidates = Self.trustMaterialCandidates(forAny: [deviceId])
        guard !candidates.isEmpty else { return }
        let validKeys = KEMPublicKeyInfo.normalizedValidKeys(kemPublicKeys)
        guard !validKeys.isEmpty else { return }

        let observedAt = Date()
        for candidate in candidates {
            if let existing = cache[candidate],
               existing.source == "signed_lan_kem_refresh",
               existing.expiresAt.map({ $0 > observedAt }) ?? true {
                continue
            }
            let existing = cache[candidate]
            let existingKeys: [UInt16: Data]
            if existing?.source == "signed_lan_kem_refresh",
               existing?.expiresAt.map({ $0 <= observedAt }) == true {
                existingKeys = [:]
            } else {
                existingKeys = existing?.keys ?? [:]
            }
            var dict: [UInt16: Data] = existingKeys
            for keyInfo in validKeys {
                dict[keyInfo.suiteWireId] = keyInfo.publicKey
            }
            cache[candidate] = StoredPeer(
                keys: dict,
                updatedAt: observedAt,
                source: "pairing_identity_exchange"
            )
        }
        pruneCacheIfNeeded()
        save(restoring: previousCache)
    }

    /// Imports join/bootstrap KEM material only after its protocol identity has
    /// been validated and pinned by the current-path admission transaction.
    /// This is intentionally separate from the legacy pairing upsert: strict
    /// handshake lookup can distinguish authority-bound bootstrap keys from
    /// unbound discovery material.
    @discardableResult
    func upsertAuthorityBoundBootstrap(
        deviceIds: [String],
        kemPublicKeys: [KEMPublicKeyInfo],
        verifiedProtocolFingerprint: String
    ) throws -> AuthorityBoundMutationReceipt {
        let prepared = try prepareAuthorityBoundBootstrap(
            deviceIds: deviceIds,
            kemPublicKeys: kemPublicKeys,
            verifiedProtocolFingerprint: verifiedProtocolFingerprint
        )
        try applyPreparedAuthorityBoundMutation(prepared, permitsJournal: false)
        return prepared.receipt
    }

    func prepareAuthorityBoundBootstrap(
        deviceIds: [String],
        kemPublicKeys: [KEMPublicKeyInfo],
        verifiedProtocolFingerprint: String,
        outerPermit: PairingIdentityAuthorityMutationPermit? = nil
    ) throws -> PreparedAuthorityBoundMutation {
        try requirePersistenceAvailable(outerPermit: outerPermit)
        guard let fingerprint = Self.normalizedFingerprint(verifiedProtocolFingerprint) else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Authority-bound KEM bootstrap has an invalid protocol fingerprint"
            )
        }
        let candidates = Self.authorityBoundTrustMaterialCandidates(forAny: deviceIds)
        let validKeys = KEMPublicKeyInfo.normalizedValidKeys(kemPublicKeys)
        guard !candidates.isEmpty, !validKeys.isEmpty else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Authority-bound KEM bootstrap has no valid peer or KEM key"
            )
        }

        let previousCache = cache
        var candidateCache = cache
        let observedAt = Date()
        let keyDict = Dictionary(uniqueKeysWithValues: validKeys.map { ($0.suiteWireId, $0.publicKey) })
        for candidate in candidates {
            if var existing = candidateCache[candidate] {
                var bootstraps = existing.authorityBoundBootstraps ?? [:]
                bootstraps[fingerprint] = StoredPeer.AuthorityBoundBootstrap(
                    keys: keyDict,
                    updatedAt: observedAt
                )
                existing.authorityBoundBootstraps = Self.prunedAuthorityBoundBootstraps(
                    bootstraps
                )
                existing.updatedAt = max(existing.updatedAt, observedAt)
                candidateCache[candidate] = existing
            } else {
                candidateCache[candidate] = StoredPeer(
                    keys: keyDict,
                    updatedAt: observedAt,
                    source: "authority_bound_join_bootstrap",
                    protocolIdentityFingerprint: fingerprint,
                    signingFingerprint: fingerprint,
                    authorityBoundBootstraps: [
                        fingerprint: StoredPeer.AuthorityBoundBootstrap(
                            keys: keyDict,
                            updatedAt: observedAt
                        )
                    ]
                )
            }
        }
        Self.pruneCacheIfNeeded(&candidateCache)
        let authorityCandidates = Set(candidates)
        let receipt = AuthorityBoundMutationReceipt(
            entries: Set(previousCache.keys).union(candidateCache.keys).sorted().compactMap { candidate in
                let previous = previousCache[candidate]
                let committed = candidateCache[candidate]
                guard previous != committed else { return nil }
                return AuthorityBoundEntryMutation(
                    deviceId: candidate,
                    previous: previous,
                    committed: committed,
                    bootstrapFingerprint: authorityCandidates.contains(candidate)
                        ? fingerprint
                        : nil
                )
            }
        )
        return PreparedAuthorityBoundMutation(
            before: try snapshot(of: previousCache),
            after: try snapshot(of: candidateCache),
            receipt: receipt
        )
    }

    /// Applies a mutation whose exact before/after images are already durable
    /// in the cross-store journal. `permitsJournal` is deliberately internal;
    /// ordinary callers remain quarantined while that journal exists.
    func applyPreparedAuthorityBoundMutation(
        _ prepared: PreparedAuthorityBoundMutation,
        permitsJournal: Bool
    ) throws {
        try requirePersistenceBackingAvailable()
        if !permitsJournal, isAuthorityJournalQuarantined {
            throw PersistenceError.authorityTransactionQuarantined
        }
        let before = try decodedCache(from: prepared.before)
        guard cache == before else {
            throw PersistenceError.concurrentModification
        }
        let after = try decodedCache(from: prepared.after)
        try persist(after, permitsJournal: permitsJournal)
        cache = after
    }

    func currentAuthorityBoundSnapshotIgnoringJournal() throws -> AuthorityBoundSnapshot {
        try requirePersistenceBackingAvailable()
        return try snapshot(of: cache)
    }

    func restoreAuthorityBoundSnapshotIgnoringJournal(
        _ snapshot: AuthorityBoundSnapshot,
        expectedCurrent: [AuthorityBoundSnapshot]
    ) throws {
        try requirePersistenceBackingAvailable()
        let expectedCaches = try expectedCurrent.map { try decodedCache(from: $0) }
        guard expectedCaches.contains(cache) else {
            throw PersistenceError.concurrentModification
        }
        let restored = try decodedCache(from: snapshot)
        try persist(restored, permitsJournal: true)
        cache = restored
    }

    func authorityBoundSnapshotMatchesIgnoringJournal(
        _ snapshot: AuthorityBoundSnapshot
    ) throws -> Bool {
        try requirePersistenceBackingAvailable()
        return cache == (try decodedCache(from: snapshot))
    }

    func rollbackAuthorityBoundMutation(
        _ receipt: AuthorityBoundMutationReceipt,
        permitsJournal: Bool = false
    ) throws {
        try requirePersistenceBackingAvailable()
        if !permitsJournal, isAuthorityJournalQuarantined {
            throw PersistenceError.authorityTransactionQuarantined
        }
        var candidateCache = cache
        for entry in receipt.entries {
            if let fingerprint = entry.bootstrapFingerprint {
                let current = candidateCache[entry.deviceId]?
                    .authorityBoundBootstraps?[fingerprint]
                let committed = entry.committed?.authorityBoundBootstraps?[fingerprint]
                let previous = entry.previous?.authorityBoundBootstraps?[fingerprint]
                guard current == committed || current == previous else {
                    throw PersistenceError.concurrentModification
                }
            } else {
                let current = candidateCache[entry.deviceId]
                guard current == entry.committed || current == entry.previous else {
                    throw PersistenceError.concurrentModification
                }
            }
        }
        for entry in receipt.entries {
            if let fingerprint = entry.bootstrapFingerprint {
                let committedBootstrap = entry.committed?
                    .authorityBoundBootstraps?[fingerprint]
                let previousBootstrap = entry.previous?
                    .authorityBoundBootstraps?[fingerprint]
                let currentBootstrap = candidateCache[entry.deviceId]?
                    .authorityBoundBootstraps?[fingerprint]
                guard currentBootstrap == committedBootstrap,
                      committedBootstrap != previousBootstrap else {
                    continue
                }
                guard var current = candidateCache[entry.deviceId] else {
                    throw PersistenceError.concurrentModification
                }
                let currentWasExactCommitted = current == entry.committed
                var bootstraps = current.authorityBoundBootstraps ?? [:]
                if let previousBootstrap {
                    bootstraps[fingerprint] = previousBootstrap
                } else {
                    bootstraps.removeValue(forKey: fingerprint)
                }
                current.authorityBoundBootstraps = bootstraps.isEmpty ? nil : bootstraps

                if current.updatedAt == entry.committed?.updatedAt,
                   let previousUpdatedAt = entry.previous?.updatedAt {
                    current.updatedAt = previousUpdatedAt
                }

                if entry.previous == nil {
                    if let newest = bootstraps.max(by: {
                        $0.value.updatedAt < $1.value.updatedAt
                    }) {
                        if current.keys == entry.committed?.keys {
                            current.keys = newest.value.keys
                        }
                        if current.source == entry.committed?.source {
                            current.source = "authority_bound_join_bootstrap"
                        }
                        if current.protocolIdentityFingerprint
                            == entry.committed?.protocolIdentityFingerprint {
                            current.protocolIdentityFingerprint = newest.key
                        }
                        if current.signingFingerprint
                            == entry.committed?.signingFingerprint {
                            current.signingFingerprint = newest.key
                        }
                        current.updatedAt = max(current.updatedAt, newest.value.updatedAt)
                    } else if currentWasExactCommitted {
                        candidateCache.removeValue(forKey: entry.deviceId)
                        continue
                    } else {
                        if current.keys == entry.committed?.keys {
                            current.keys = [:]
                        }
                        if current.source == entry.committed?.source {
                            current.source = nil
                        }
                        if current.protocolIdentityFingerprint
                            == entry.committed?.protocolIdentityFingerprint {
                            current.protocolIdentityFingerprint = nil
                        }
                        if current.signingFingerprint
                            == entry.committed?.signingFingerprint {
                            current.signingFingerprint = nil
                        }
                    }
                }
                candidateCache[entry.deviceId] = current
            } else if candidateCache[entry.deviceId] == entry.committed,
                      entry.committed != entry.previous {
                if let previous = entry.previous {
                    candidateCache[entry.deviceId] = previous
                } else {
                    candidateCache.removeValue(forKey: entry.deviceId)
                }
            }
        }
        if candidateCache != cache {
            try persist(candidateCache, permitsJournal: permitsJournal)
            cache = candidateCache
        }
    }

    func rollForwardAuthorityBoundMutation(
        _ receipt: AuthorityBoundMutationReceipt,
        permitsJournal: Bool = false
    ) throws {
        try requirePersistenceBackingAvailable()
        if !permitsJournal, isAuthorityJournalQuarantined {
            throw PersistenceError.authorityTransactionQuarantined
        }
        var candidateCache = cache
        for entry in receipt.entries {
            if let fingerprint = entry.bootstrapFingerprint {
                let current = candidateCache[entry.deviceId]?
                    .authorityBoundBootstraps?[fingerprint]
                let previous = entry.previous?.authorityBoundBootstraps?[fingerprint]
                let committed = entry.committed?.authorityBoundBootstraps?[fingerprint]
                guard current == previous || current == committed else {
                    throw PersistenceError.concurrentModification
                }
            } else {
                let current = candidateCache[entry.deviceId]
                guard current == entry.previous || current == entry.committed else {
                    throw PersistenceError.concurrentModification
                }
            }
        }

        for entry in receipt.entries {
            if candidateCache[entry.deviceId] == entry.previous,
               entry.previous != entry.committed {
                if let committed = entry.committed {
                    candidateCache[entry.deviceId] = committed
                } else {
                    candidateCache.removeValue(forKey: entry.deviceId)
                }
                continue
            }
            guard let fingerprint = entry.bootstrapFingerprint else { continue }
            let previousBootstrap = entry.previous?
                .authorityBoundBootstraps?[fingerprint]
            let committedBootstrap = entry.committed?
                .authorityBoundBootstraps?[fingerprint]
            let currentBootstrap = candidateCache[entry.deviceId]?
                .authorityBoundBootstraps?[fingerprint]
            guard currentBootstrap == previousBootstrap,
                  previousBootstrap != committedBootstrap else {
                continue
            }
            guard var current = candidateCache[entry.deviceId] else {
                guard let committed = entry.committed else {
                    throw PersistenceError.concurrentModification
                }
                candidateCache[entry.deviceId] = committed
                continue
            }
            var bootstraps = current.authorityBoundBootstraps ?? [:]
            if let committedBootstrap {
                bootstraps[fingerprint] = committedBootstrap
                current.updatedAt = max(current.updatedAt, committedBootstrap.updatedAt)
            } else {
                bootstraps.removeValue(forKey: fingerprint)
            }
            current.authorityBoundBootstraps = bootstraps.isEmpty ? nil : bootstraps
            candidateCache[entry.deviceId] = current
        }
        if candidateCache != cache {
            try persist(candidateCache, permitsJournal: permitsJournal)
            cache = candidateCache
        }
    }

    func authorityBoundMutationMatchesCommittedIgnoringJournal(
        _ receipt: AuthorityBoundMutationReceipt
    ) throws -> Bool {
        try requirePersistenceBackingAvailable()
        return authorityBoundMutation(receipt, matchesCommitted: true)
    }

    func authorityBoundMutationMatchesRolledBackIgnoringJournal(
        _ receipt: AuthorityBoundMutationReceipt
    ) throws -> Bool {
        try requirePersistenceBackingAvailable()
        return authorityBoundMutation(receipt, matchesCommitted: false)
    }

    private func authorityBoundMutation(
        _ receipt: AuthorityBoundMutationReceipt,
        matchesCommitted: Bool
    ) -> Bool {
        receipt.entries.allSatisfy { entry in
            if let fingerprint = entry.bootstrapFingerprint {
                let current = cache[entry.deviceId]?
                    .authorityBoundBootstraps?[fingerprint]
                let expected = matchesCommitted
                    ? entry.committed?.authorityBoundBootstraps?[fingerprint]
                    : entry.previous?.authorityBoundBootstraps?[fingerprint]
                return current == expected
            }
            return cache[entry.deviceId] == (matchesCommitted ? entry.committed : entry.previous)
        }
    }

    public func upsertSignedKEMRefresh(
        deviceIds: [String],
        payload: AppMessage.SignedKEMRefreshPayload,
        request: AppMessage.KEMRefreshRequestPayload,
        pinnedProtocolFingerprints: Set<String>,
        minimumGeneration: UInt64?,
        recoveryEvidenceReference: String? = nil
    ) async throws {
        try requirePersistenceAvailable()
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
        let candidates = Self.trustMaterialCandidates(forAny: identifiers)
        guard !candidates.isEmpty else { return }

        let keyDict = Dictionary(uniqueKeysWithValues: validKeys.map { ($0.suiteWireId, $0.publicKey) })
        let payloadHash = Self.sha256Hex(validPayload.signaturePreimage)
        let requestHash = request.canonicalRequestHashHex
        let canonicalRecoveryReference = recoveryEvidenceReference.flatMap {
            Self.canonicalEvidenceReference($0)
        }
        let observedAt = Date()
        var candidateCache = cache
        for candidate in candidates {
            candidateCache[candidate] = StoredPeer(
                keys: keyDict,
                updatedAt: observedAt,
                source: "signed_lan_kem_refresh",
                keyId: validPayload.keyId,
                generation: validPayload.generation,
                expiresAt: validPayload.expiresAt,
                protocolIdentityFingerprint: validPayload.protocolIdentityFingerprint,
                signingFingerprint: validPayload.protocolIdentityFingerprint,
                payloadHashHex: payloadHash,
                requestHashHex: requestHash,
                recoveryEvidenceReference: canonicalRecoveryReference,
                signedSuiteWireIds: validKeys.map(\.suiteWireId).sorted(),
                signedRefreshDeviceId: validPayload.deviceId
            )
        }
        Self.pruneCacheIfNeeded(&candidateCache)
        try persist(candidateCache)
        cache = candidateCache
    }

    public func kemPublicKeys(for deviceId: String) -> [CryptoSuite: Data] {
        kemPublicKeys(forAny: [deviceId])
    }

    public func kemPublicKeys(forAny deviceIds: [String]) -> [CryptoSuite: Data] {
        guard persistenceFailureReason == nil, !isAuthorityJournalQuarantined else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: selectKEMPublicKeys(for: deviceIds).map { suite, selected in
                (suite, selected.publicKey)
            }
        )
    }

    public func signedRefreshKEMPublicKeys(
        forAny deviceIds: [String],
        pinnedProtocolFingerprints: Set<String>
    ) -> [CryptoSuite: Data] {
        guard persistenceFailureReason == nil, !isAuthorityJournalQuarantined else { return [:] }
        let normalizedPins = Set(pinnedProtocolFingerprints.compactMap(Self.normalizedFingerprint))
        guard !normalizedPins.isEmpty else { return [:] }
        let candidates = Self.trustMaterialCandidates(forAny: deviceIds)
        let canonicalCandidates = Self.canonicalLookupCandidates(for: deviceIds)
        guard !candidates.isEmpty else { return [:] }

        var selected: [CryptoSuite: SelectedKey] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard let peer = cache[candidate],
                  peer.source == "signed_lan_kem_refresh",
                  Self.peer(peer, isBoundToAny: normalizedPins) else {
                continue
            }
            if let expiresAt = peer.expiresAt, expiresAt <= Date() { continue }
            let signedSuiteWireIds = Set(peer.signedSuiteWireIds ?? peer.keys.keys.sorted())
            for (suiteWireId, publicKey) in Self.sanitizedKEMMap(peer.keys)
            where signedSuiteWireIds.contains(suiteWireId) {
                let suite = CryptoSuite(wireId: suiteWireId)
                let candidateKey = SelectedKey(
                    publicKey: publicKey,
                    updatedAt: peer.updatedAt,
                    isCanonical: canonicalCandidates.contains(candidate),
                    isSignedRefresh: true,
                    lookupIndex: index
                )
                if Self.shouldPrefer(candidateKey, over: selected[suite]) {
                    selected[suite] = candidateKey
                }
            }
        }

        return Dictionary(uniqueKeysWithValues: selected.map { ($0.key, $0.value.publicKey) })
    }

    public func authorityBoundBootstrapKEMPublicKeys(
        forAny deviceIds: [String],
        pinnedProtocolFingerprints: Set<String>
    ) -> [CryptoSuite: Data] {
        guard persistenceFailureReason == nil, !isAuthorityJournalQuarantined else { return [:] }
        let normalizedPins = Set(pinnedProtocolFingerprints.compactMap(Self.normalizedFingerprint))
        guard !normalizedPins.isEmpty else { return [:] }
        let candidates = Self.trustMaterialCandidates(forAny: deviceIds)
        let canonicalCandidates = Self.canonicalLookupCandidates(for: deviceIds)
        var selected: [CryptoSuite: SelectedKey] = [:]

        for (index, candidate) in candidates.enumerated() {
            guard let peer = cache[candidate] else { continue }
            let bootstraps = peer.authorityBoundBootstraps
                ?? Self.legacyAuthorityBoundBootstraps(from: peer)
            for fingerprint in normalizedPins {
                guard let bootstrap = bootstraps[fingerprint] else { continue }
                for (suiteWireId, publicKey) in Self.sanitizedKEMMap(bootstrap.keys) {
                    let suite = CryptoSuite(wireId: suiteWireId)
                    let candidateKey = SelectedKey(
                        publicKey: publicKey,
                        updatedAt: bootstrap.updatedAt,
                        isCanonical: canonicalCandidates.contains(candidate),
                        isSignedRefresh: false,
                        lookupIndex: index
                    )
                    if Self.shouldPrefer(candidateKey, over: selected[suite]) {
                        selected[suite] = candidateKey
                    }
                }
            }
        }
        return Dictionary(uniqueKeysWithValues: selected.map { ($0.key, $0.value.publicKey) })
    }

    private func selectKEMPublicKeys(for deviceIds: [String]) -> [CryptoSuite: SelectedKey] {
        let candidates = Self.trustMaterialCandidates(forAny: deviceIds)
        let canonicalCandidates = Self.canonicalLookupCandidates(for: deviceIds)
        var selected: [CryptoSuite: SelectedKey] = [:]

        for (index, candidate) in candidates.enumerated() {
            guard let stored = cache[candidate] else { continue }
            if let expiresAt = stored.expiresAt, expiresAt <= Date() { continue }
            let isCanonical = canonicalCandidates.contains(candidate)
            let signedSuiteWireIds = Set(stored.signedSuiteWireIds ?? (stored.source == "signed_lan_kem_refresh" ? Array(stored.keys.keys) : []))
            for (wireId, pk) in Self.sanitizedKEMMap(stored.keys) {
                let suite = CryptoSuite(wireId: wireId)
                let candidateKey = SelectedKey(
                    publicKey: pk,
                    updatedAt: stored.updatedAt,
                    isCanonical: isCanonical,
                    isSignedRefresh: stored.source == "signed_lan_kem_refresh" && signedSuiteWireIds.contains(wireId),
                    lookupIndex: index
                )
                if Self.shouldPrefer(candidateKey, over: selected[suite]) {
                    selected[suite] = candidateKey
                }
            }
        }
        return selected
    }

    public func maximumKEMGeneration(forAny deviceIds: [String]) -> UInt64? {
        guard persistenceFailureReason == nil, !isAuthorityJournalQuarantined else { return nil }
        var maximum: UInt64?
        for candidate in Self.trustMaterialCandidates(forAny: deviceIds) {
            guard let generation = cache[candidate]?.generation else { continue }
            maximum = max(maximum ?? generation, generation)
        }
        return maximum
    }

    public func signedRefreshEvidence(forAny deviceIds: [String]) -> SignedRefreshEvidence? {
        guard persistenceFailureReason == nil, !isAuthorityJournalQuarantined else { return nil }
        var selected: SignedRefreshEvidence?
        for candidate in Self.trustMaterialCandidates(forAny: deviceIds) {
            guard let stored = cache[candidate],
                  stored.source == "signed_lan_kem_refresh" else {
                continue
            }
            if let expiresAt = stored.expiresAt, expiresAt <= Date() { continue }
            let evidence = SignedRefreshEvidence(
                deviceId: stored.signedRefreshDeviceId ?? candidate,
                suiteWireIds: stored.signedSuiteWireIds ?? stored.keys.keys.sorted(),
                source: stored.source,
                keyId: stored.keyId,
                generation: stored.generation,
                expiresAt: stored.expiresAt,
                protocolIdentityFingerprint: stored.protocolIdentityFingerprint,
                signingFingerprint: stored.signingFingerprint ?? stored.protocolIdentityFingerprint,
                payloadHashHex: stored.payloadHashHex,
                requestHashHex: stored.requestHashHex,
                recoveryEvidenceReference: stored.recoveryEvidenceReference,
                updatedAt: stored.updatedAt
            )
            if selected.map({ evidence.updatedAt > $0.updatedAt }) ?? true {
                selected = evidence
            }
        }
        return selected
    }

    public func clear(deviceId: String) {
        guard !isAuthorityJournalQuarantined else { return }
        let previousCache = cache
        for candidate in Self.trustMaterialCandidates(forAny: [deviceId]) {
            cache.removeValue(forKey: candidate)
        }
        save(restoring: previousCache)
    }

    @discardableResult
    func clearWithReceipt(deviceId: String) throws -> AuthorityBoundMutationReceipt {
        try requirePersistenceAvailable()
        let candidates = Set(Self.trustMaterialCandidates(forAny: [deviceId]))
        let previousCache = cache
        var candidateCache = cache
        for candidate in candidates {
            candidateCache.removeValue(forKey: candidate)
        }
        let entries = candidates.sorted().compactMap { candidate -> AuthorityBoundEntryMutation? in
            let previous = previousCache[candidate]
            let committed = candidateCache[candidate]
            guard previous != committed else { return nil }
            return AuthorityBoundEntryMutation(
                deviceId: candidate,
                previous: previous,
                committed: committed,
                bootstrapFingerprint: nil
            )
        }
        if !entries.isEmpty {
            try persist(candidateCache)
            cache = candidateCache
        }
        return AuthorityBoundMutationReceipt(entries: entries)
    }

    public func rebindCanonicalDeviceId(_ canonicalDeviceId: String, legacyIdentifiers: [String]) {
        guard !isAuthorityJournalQuarantined else { return }
        let previousCache = cache
        guard let canonical = PeerIdentityAliasResolver.persistentDeviceId(from: canonicalDeviceId) else {
            return
        }

        let canonicalCandidates = Set(PeerIdentityAliasResolver.lookupCandidates(for: canonical))
        let migrationCandidates = Self.orderedMigrationCandidates(
            canonicalDeviceId: canonical,
            legacyIdentifiers: legacyIdentifiers
        )

        var mergedKeys: [UInt16: (publicKey: Data, updatedAt: Date, isCanonical: Bool, isSignedRefresh: Bool)] = [:]
        var selectedSignedEvidence: StoredPeer?
        var mergedAuthorityBoundBootstraps: [String: StoredPeer.AuthorityBoundBootstrap] = [:]
        for candidate in migrationCandidates {
            guard let stored = cache[candidate] else { continue }
            let isCanonicalCandidate = canonicalCandidates.contains(candidate)
            let sanitizedKeys = Self.sanitizedKEMMap(stored.keys)
            let signedSuiteWireIds = Set(stored.signedSuiteWireIds ?? (stored.source == "signed_lan_kem_refresh" ? Array(sanitizedKeys.keys) : []))
            if stored.source == "signed_lan_kem_refresh",
               stored.expiresAt.map({ $0 > Date() }) ?? true,
               !sanitizedKeys.isEmpty,
               selectedSignedEvidence.map({ stored.updatedAt > $0.updatedAt }) ?? true {
                selectedSignedEvidence = stored
            }
            for (fingerprint, bootstrap) in stored.authorityBoundBootstraps
                ?? Self.legacyAuthorityBoundBootstraps(from: stored) {
                guard let normalizedFingerprint = Self.normalizedFingerprint(fingerprint) else {
                    continue
                }
                let sanitizedKeys = Self.sanitizedKEMMap(bootstrap.keys)
                guard !sanitizedKeys.isEmpty else { continue }
                if let current = mergedAuthorityBoundBootstraps[normalizedFingerprint],
                   current.updatedAt >= bootstrap.updatedAt {
                    continue
                }
                mergedAuthorityBoundBootstraps[normalizedFingerprint] = .init(
                    keys: sanitizedKeys,
                    updatedAt: bootstrap.updatedAt
                )
            }
            for (wireId, publicKey) in sanitizedKeys {
                let isSignedRefresh = stored.source == "signed_lan_kem_refresh" && signedSuiteWireIds.contains(wireId)
                if let existing = mergedKeys[wireId] {
                    if isSignedRefresh != existing.isSignedRefresh {
                        if isSignedRefresh {
                            mergedKeys[wireId] = (publicKey, stored.updatedAt, isCanonicalCandidate, isSignedRefresh)
                        }
                    } else if stored.updatedAt > existing.updatedAt
                        || (stored.updatedAt == existing.updatedAt
                            && isCanonicalCandidate
                            && !existing.isCanonical) {
                        mergedKeys[wireId] = (publicKey, stored.updatedAt, isCanonicalCandidate, isSignedRefresh)
                    }
                } else {
                    mergedKeys[wireId] = (publicKey, stored.updatedAt, isCanonicalCandidate, isSignedRefresh)
                }
            }
        }
        guard !mergedKeys.isEmpty else { return }

        let reboundSignedSuiteWireIds = selectedSignedEvidence
            .map { evidence in
                Set(evidence.signedSuiteWireIds ?? Self.sanitizedKEMMap(evidence.keys).keys.sorted())
                    .filter { mergedKeys[$0] != nil }
                    .sorted()
            }
        let rebound = StoredPeer(
            keys: Dictionary(uniqueKeysWithValues: mergedKeys.map { ($0.key, $0.value.publicKey) }),
            updatedAt: mergedKeys.values.map(\.updatedAt).max() ?? Date(),
            source: selectedSignedEvidence?.source,
            keyId: selectedSignedEvidence?.keyId,
            generation: selectedSignedEvidence?.generation,
            expiresAt: selectedSignedEvidence?.expiresAt,
            protocolIdentityFingerprint: selectedSignedEvidence?.protocolIdentityFingerprint,
            signingFingerprint: selectedSignedEvidence?.signingFingerprint,
            payloadHashHex: selectedSignedEvidence?.payloadHashHex,
            requestHashHex: selectedSignedEvidence?.requestHashHex,
            recoveryEvidenceReference: selectedSignedEvidence?.recoveryEvidenceReference,
            signedSuiteWireIds: reboundSignedSuiteWireIds,
            signedRefreshDeviceId: selectedSignedEvidence?.signedRefreshDeviceId,
            authorityBoundBootstraps: Self.prunedAuthorityBoundBootstraps(
                mergedAuthorityBoundBootstraps
            )
        )
        for candidate in Set(migrationCandidates) where !canonicalCandidates.contains(candidate) {
            cache.removeValue(forKey: candidate)
        }
        for candidate in canonicalCandidates {
            cache[candidate] = rebound
        }
        save(restoring: previousCache)
    }

#if DEBUG || SKYBRIDGE_TESTING
    public func clearForTesting() {
        guard !isAuthorityJournalQuarantined else { return }
        let previousCache = cache
        cache.removeAll()
        save(restoring: previousCache)
    }

    func testOnlyReplaceWithAuthorityBoundPeers(
        deviceIds: [String],
        kemPublicKey: KEMPublicKeyInfo,
        protocolFingerprint: String
    ) throws {
        try requirePersistenceAvailable()
        guard let fingerprint = Self.normalizedFingerprint(protocolFingerprint),
              let validKey = KEMPublicKeyInfo.normalizedValidKeys([kemPublicKey]).first else {
            throw SkyBridgeError.invalidKeyData(reason: "Invalid test authority material")
        }
        let observedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let keys = [validKey.suiteWireId: validKey.publicKey]
        let bootstrap = StoredPeer.AuthorityBoundBootstrap(
            keys: keys,
            updatedAt: observedAt
        )
        let candidateCache = Dictionary(uniqueKeysWithValues: deviceIds.map { deviceId in
            (
                deviceId,
                StoredPeer(
                    keys: keys,
                    updatedAt: observedAt,
                    source: "authority_bound_join_bootstrap",
                    protocolIdentityFingerprint: fingerprint,
                    signingFingerprint: fingerprint,
                    authorityBoundBootstraps: [fingerprint: bootstrap]
                )
            )
        })
        try persist(candidateCache)
        cache = candidateCache
    }

    func testOnlyStoredPeerCount() -> Int {
        cache.count
    }
#endif

    private static func loadCache(
        storageKey: String,
        userDefaults: UserDefaults
    ) throws -> [String: StoredPeer] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        let decoded: [String: StoredPeer]
        do {
            decoded = try JSONDecoder().decode([String: StoredPeer].self, from: data)
        } catch {
            throw PersistenceError.decodingFailed(error.localizedDescription)
        }
        return Dictionary(
            uniqueKeysWithValues: decoded.compactMap { deviceId, peer in
                guard let normalizedDeviceId = PeerIdentityAliasResolver.normalizedIdentifier(deviceId),
                      normalizedDeviceId == deviceId,
                      PeerIdentityAliasResolver.persistentDeviceId(from: normalizedDeviceId) != nil,
                      let sanitizedPeer = Self.sanitizedPeer(peer) else {
                    return nil
                }
                return (normalizedDeviceId, sanitizedPeer)
            }
        )
    }

    private static func sanitizedPeer(_ peer: StoredPeer) -> StoredPeer? {
        var sanitized = peer
        sanitized.keys = sanitizedKEMMap(peer.keys)
        guard !sanitized.keys.isEmpty else { return nil }
        if let signedSuiteWireIds = sanitized.signedSuiteWireIds {
            sanitized.signedSuiteWireIds = signedSuiteWireIds
                .filter { sanitized.keys[$0] != nil }
                .sorted()
        }
        sanitized.payloadHashHex = normalizedFingerprint(peer.payloadHashHex)
        sanitized.requestHashHex = normalizedFingerprint(peer.requestHashHex)
        sanitized.recoveryEvidenceReference = peer.recoveryEvidenceReference
            .flatMap(canonicalEvidenceReference)
        let bootstraps = sanitized.authorityBoundBootstraps
            ?? legacyAuthorityBoundBootstraps(from: sanitized)
        sanitized.authorityBoundBootstraps = prunedAuthorityBoundBootstraps(
            Dictionary(uniqueKeysWithValues: bootstraps.compactMap { fingerprint, bootstrap in
                guard let normalizedFingerprint = normalizedFingerprint(fingerprint) else {
                    return nil
                }
                let keys = sanitizedKEMMap(bootstrap.keys)
                guard !keys.isEmpty else { return nil }
                return (
                    normalizedFingerprint,
                    StoredPeer.AuthorityBoundBootstrap(
                        keys: keys,
                        updatedAt: bootstrap.updatedAt
                    )
                )
            })
        )
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

    private static func migrationCandidates(for identifier: String) -> [String] {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            ordered.append(value)
        }

        for candidate in Self.trustMaterialCandidates(forAny: [trimmed]) {
            append(candidate)
        }
        return ordered
    }

    private static func lookupCandidates(forAny identifiers: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            guard !value.isEmpty, seen.insert(value).inserted else { return }
            ordered.append(value)
        }

        for identifier in identifiers {
            for candidate in PeerIdentityAliasResolver.lookupCandidates(for: identifier) {
                append(candidate)
            }
        }

        return ordered
    }

    private static func trustMaterialCandidates(forAny identifiers: [String]) -> [String] {
        lookupCandidates(forAny: identifiers).filter {
            PeerIdentityAliasResolver.persistentDeviceId(from: $0) != nil
        }
    }

    private static func authorityBoundTrustMaterialCandidates(
        forAny identifiers: [String]
    ) -> [String] {
        let persistentIdentifiers = identifiers.compactMap {
            PeerIdentityAliasResolver.authorityBoundPersistentDeviceId(from: $0)
        }
        return trustMaterialCandidates(forAny: persistentIdentifiers)
    }

    private static func canonicalLookupCandidates(for identifiers: [String]) -> Set<String> {
        var candidates = Set<String>()
        for identifier in identifiers {
            guard let canonical = PeerIdentityAliasResolver.persistentDeviceId(from: identifier) else {
                continue
            }
            candidates.formUnion(PeerIdentityAliasResolver.lookupCandidates(for: canonical))
        }
        return candidates
    }

    private static func shouldPrefer(_ candidate: SelectedKey, over existing: SelectedKey?) -> Bool {
        guard let existing else { return true }
        if candidate.isSignedRefresh != existing.isSignedRefresh {
            return candidate.isSignedRefresh
        }
        if candidate.updatedAt != existing.updatedAt {
            return candidate.updatedAt > existing.updatedAt
        }
        if candidate.isCanonical != existing.isCanonical {
            return candidate.isCanonical
        }
        return candidate.lookupIndex < existing.lookupIndex
    }

    private static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private static func peer(_ peer: StoredPeer, isBoundToAny normalizedPins: Set<String>) -> Bool {
        [
            normalizedFingerprint(peer.signingFingerprint),
            normalizedFingerprint(peer.protocolIdentityFingerprint)
        ]
        .compactMap { $0 }
        .contains { normalizedPins.contains($0) }
    }

    private static func legacyAuthorityBoundBootstraps(
        from peer: StoredPeer
    ) -> [String: StoredPeer.AuthorityBoundBootstrap] {
        guard peer.source == "authority_bound_join_bootstrap",
              let fingerprint = normalizedFingerprint(
                peer.signingFingerprint ?? peer.protocolIdentityFingerprint
              ) else {
            return [:]
        }
        return [
            fingerprint: StoredPeer.AuthorityBoundBootstrap(
                keys: sanitizedKEMMap(peer.keys),
                updatedAt: peer.updatedAt
            )
        ]
    }

    private static func prunedAuthorityBoundBootstraps(
        _ bootstraps: [String: StoredPeer.AuthorityBoundBootstrap]
    ) -> [String: StoredPeer.AuthorityBoundBootstrap]? {
        guard !bootstraps.isEmpty else { return nil }
        return Dictionary(
            uniqueKeysWithValues: bootstraps
                .sorted { lhs, rhs in
                    if lhs.value.updatedAt != rhs.value.updatedAt {
                        return lhs.value.updatedAt > rhs.value.updatedAt
                    }
                    return lhs.key < rhs.key
                }
                .prefix(maximumAuthorityBoundBootstrapsPerPeer)
                .map { ($0.key, $0.value) }
        )
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

    private func persist(
        _ candidateCache: [String: StoredPeer],
        permitsJournal: Bool = false
    ) throws {
        try requirePersistenceBackingAvailable()
        if !permitsJournal, isAuthorityJournalQuarantined {
            throw PersistenceError.authorityTransactionQuarantined
        }
        let previousData = userDefaults.data(forKey: storageKey)
        let data: Data
        do {
            data = try JSONEncoder().encode(candidateCache)
        } catch {
            let failure = PersistenceError.encodingFailed(error.localizedDescription)
            persistenceFailureReason = failure.localizedDescription
            throw failure
        }
        userDefaults.set(data, forKey: storageKey)
        guard userDefaults.data(forKey: storageKey) == data else {
            if let previousData {
                userDefaults.set(previousData, forKey: storageKey)
            } else {
                userDefaults.removeObject(forKey: storageKey)
            }
            let failure = PersistenceError.writeVerificationFailed
            persistenceFailureReason = failure.localizedDescription
            throw failure
        }
    }

    private func requirePersistenceAvailable(
        outerPermit: PairingIdentityAuthorityMutationPermit? = nil
    ) throws {
        try requirePersistenceBackingAvailable()
        guard !authorityJournalExists() else {
            throw PersistenceError.authorityTransactionQuarantined
        }
        if pairingAcceptanceJournalExists() {
            guard let outerPermit,
                  PairingAcceptanceJournalStore.permitOwnsActiveJournal(outerPermit) else {
                throw PersistenceError.authorityTransactionQuarantined
            }
        }
    }

    private func requirePersistenceBackingAvailable() throws {
        if let persistenceFailureReason {
            throw PersistenceError.persistenceUnavailable(persistenceFailureReason)
        }
    }

    private var isAuthorityJournalQuarantined: Bool {
        authorityJournalExists() || pairingAcceptanceJournalExists()
    }

    private func snapshot(
        of candidateCache: [String: StoredPeer]
    ) throws -> AuthorityBoundSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return AuthorityBoundSnapshot(encodedCache: try encoder.encode(candidateCache))
        } catch {
            throw PersistenceError.encodingFailed(error.localizedDescription)
        }
    }

    private func decodedCache(
        from snapshot: AuthorityBoundSnapshot
    ) throws -> [String: StoredPeer] {
        do {
            return try JSONDecoder().decode(
                [String: StoredPeer].self,
                from: snapshot.encodedCache
            )
        } catch {
            throw PersistenceError.decodingFailed(error.localizedDescription)
        }
    }

    private func save(restoring previousCache: [String: StoredPeer]) {
        do {
            try persist(cache)
        } catch {
            cache = previousCache
            SkyBridgeLogger.shared.error(
                "⛔️ KEM trust store persistence failed: \(error.localizedDescription)"
            )
        }
    }

    private func pruneCacheIfNeeded() {
        Self.pruneCacheIfNeeded(&cache)
    }

    private static func pruneCacheIfNeeded(_ cache: inout [String: StoredPeer]) {
        guard cache.count > maximumStoredPeerAliases else { return }
        let orderedEvictionCandidates = cache.sorted { lhs, rhs in
            let lhsSigned = lhs.value.source == "signed_lan_kem_refresh"
            let rhsSigned = rhs.value.source == "signed_lan_kem_refresh"
            if lhsSigned != rhsSigned { return !lhsSigned }
            if lhs.value.updatedAt != rhs.value.updatedAt {
                return lhs.value.updatedAt < rhs.value.updatedAt
            }
            return lhs.key < rhs.key
        }
        for (candidate, _) in orderedEvictionCandidates
        .prefix(cache.count - maximumStoredPeerAliases) {
            cache.removeValue(forKey: candidate)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func canonicalEvidenceReference(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count == 36, value.hasPrefix("ev1:") else {
            return nil
        }
        guard value.dropFirst(4).unicodeScalars.allSatisfy({ scalar in
            (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 97 && scalar.value <= 102)
        }) else {
            return nil
        }
        return value
    }
}

/// Stores authenticated protocol-signing identity material advertised by a
/// peer inside an already established P2P/WebRTC session. Versioned raw-key
/// bindings are authoritative when present; legacy fingerprint-only rows stay
/// readable for migration but can never overwrite a raw binding.
@available(iOS 17.0, *)
public actor ProtocolIdentityTrustStore {
    public static let shared = ProtocolIdentityTrustStore()

    public enum AuthorityBoundUpdateError: Error, LocalizedError, Sendable, Equatable {
        case persistenceUnavailable
        case authorityTransactionQuarantined
        case invalidIdentityMaterial
        case conflictingIdentity(algorithm: String)
        case encodingFailed(String)
        case writeVerificationFailed
        case concurrentModification

        public var errorDescription: String? {
            switch self {
            case .persistenceUnavailable:
                return "Protocol identity trust persistence is unavailable"
            case .authorityTransactionQuarantined:
                return "Protocol identity trust is quarantined by an incomplete pairing identity transaction"
            case .invalidIdentityMaterial:
                return "Protocol identity material is invalid"
            case .conflictingIdentity(let algorithm):
                return "Protocol identity conflicts with the stored \(algorithm) authority"
            case .encodingFailed(let reason):
                return "Protocol identity trust encoding failed: \(reason)"
            case .writeVerificationFailed:
                return "Protocol identity trust write could not be verified"
            case .concurrentModification:
                return "Protocol identity trust state changed before rollback"
            }
        }
    }

    fileprivate struct StoredPeer: Codable, Sendable, Equatable {
        var fingerprints: [String]
        var keyBindings: [StoredKeyBinding]?
        var conflictedAlgorithms: [String]?
        var updatedAt: Date
    }

    fileprivate struct AuthorityBoundEntryMutation: Codable, Sendable, Equatable {
        let deviceId: String
        let previous: StoredPeer?
        let committed: StoredPeer?
        let algorithms: Set<String>
    }

    struct AuthorityBoundMutationReceipt: Codable, Sendable, Equatable {
        fileprivate let entries: [AuthorityBoundEntryMutation]
    }

    struct AuthorityBoundSnapshot: Codable, Sendable, Equatable {
        fileprivate let encodedCache: Data
    }

    struct PreparedAuthorityBoundMutation: Sendable {
        let before: AuthorityBoundSnapshot
        let after: AuthorityBoundSnapshot
        let receipt: AuthorityBoundMutationReceipt
    }

    fileprivate struct StoredKeyBinding: Codable, Sendable, Equatable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var algorithm: String
        var fingerprint: String
        var publicKeyBase64: String

        init(key: AppMessage.ProtocolIdentityPublicKeyInfo, fingerprint: String) {
            schemaVersion = Self.currentSchemaVersion
            algorithm = key.normalizedAlgorithm?.rawValue ?? key.protocolSigningAlgorithm
            self.fingerprint = fingerprint
            publicKeyBase64 = key.publicKey.base64EncodedString()
        }

        var publicKeyBytes: Data? {
            guard let decoded = Data(base64Encoded: publicKeyBase64),
                  decoded.base64EncodedString() == publicKeyBase64 else {
                return nil
            }
            return decoded
        }
    }

    private let storageKey: String
    private let userDefaults: UserDefaults
    private let authorityJournalExists: @Sendable () -> Bool
    private let pairingAcceptanceJournalExists: @Sendable () -> Bool
    private var cache: [String: StoredPeer] = [:]
    private var persistenceAvailable = true

    init(
        storageKey: String = "protocol_identity_trust_store.v1",
        userDefaults: UserDefaults = .standard,
        authorityJournalExists: @escaping @Sendable () -> Bool = {
            AuthorityBoundPairingIdentityJournalStore.defaultJournalExists()
        },
        pairingAcceptanceJournalExists: @escaping @Sendable () -> Bool = {
            PairingAcceptanceJournalStore.defaultJournalExists()
        }
    ) {
        self.storageKey = storageKey
        self.userDefaults = userDefaults
        self.authorityJournalExists = authorityJournalExists
        self.pairingAcceptanceJournalExists = pairingAcceptanceJournalExists
        do {
            cache = try Self.loadCache(storageKey: storageKey, userDefaults: userDefaults)
        } catch {
            cache = [:]
            persistenceAvailable = false
        }
    }

    public func upsert(
        deviceId: String,
        protocolIdentityPublicKeys: [AppMessage.ProtocolIdentityPublicKeyInfo]?
    ) {
        guard !isAuthorityJournalQuarantined else { return }
        let bindings = (AppMessage.ProtocolIdentityPublicKeyInfo
            .normalizedValidKeys(protocolIdentityPublicKeys) ?? [])
            .compactMap { key -> StoredKeyBinding? in
                guard let fingerprint = Self.normalizedFingerprint(key.authoritativeFingerprint) else {
                    return nil
                }
                return StoredKeyBinding(key: key, fingerprint: fingerprint)
            }
        upsert(deviceId: deviceId, bindings: bindings)
    }

    @discardableResult
    func upsertAuthorityBound(
        deviceId: String,
        protocolIdentityPublicKeys: [AppMessage.ProtocolIdentityPublicKeyInfo]
    ) throws -> AuthorityBoundMutationReceipt {
        guard let prepared = try prepareAuthorityBoundSequence(
            deviceIds: [deviceId],
            protocolIdentityPublicKeys: protocolIdentityPublicKeys
        ).first else {
            throw AuthorityBoundUpdateError.invalidIdentityMaterial
        }
        try applyPreparedAuthorityBoundMutation(prepared, permitsJournal: false)
        return prepared.receipt
    }

    func prepareAuthorityBoundSequence(
        deviceIds: [String],
        protocolIdentityPublicKeys: [AppMessage.ProtocolIdentityPublicKeyInfo],
        outerPermit: PairingIdentityAuthorityMutationPermit? = nil
    ) throws -> [PreparedAuthorityBoundMutation] {
        try requirePersistenceAvailable(outerPermit: outerPermit)
        let bindings = normalizedBindings(
            AppMessage.ProtocolIdentityPublicKeyInfo
                .normalizedValidKeys(protocolIdentityPublicKeys)?
                .compactMap { key -> StoredKeyBinding? in
                    guard let fingerprint = Self.normalizedFingerprint(
                        key.authoritativeFingerprint
                    ) else {
                        return nil
                    }
                    return StoredKeyBinding(key: key, fingerprint: fingerprint)
                }
        )
        guard !deviceIds.isEmpty, !bindings.isEmpty else {
            throw AuthorityBoundUpdateError.invalidIdentityMaterial
        }

        var simulatedCache = cache
        var preparedMutations: [PreparedAuthorityBoundMutation] = []
        for deviceId in deviceIds {
            let candidates = Self.authorityBoundTrustMaterialCandidates(forAny: [deviceId])
            guard !candidates.isEmpty else {
                throw AuthorityBoundUpdateError.invalidIdentityMaterial
            }
            let previousCache = simulatedCache
            var candidateCache = simulatedCache
            let observedAt = Date()
            for candidate in candidates {
                let existing = candidateCache[candidate]
                var mergedBindings = normalizedBindings(existing?.keyBindings)
                var fingerprints = Set(
                    existing?.fingerprints.compactMap(Self.normalizedFingerprint) ?? []
                )
                for incoming in bindings {
                    let sameAlgorithm = mergedBindings.filter {
                        $0.algorithm == incoming.algorithm
                    }
                    guard !sameAlgorithm.contains(where: {
                        $0.fingerprint != incoming.fingerprint
                            || $0.publicKeyBase64 != incoming.publicKeyBase64
                    }) else {
                        throw AuthorityBoundUpdateError.conflictingIdentity(
                            algorithm: incoming.algorithm
                        )
                    }
                    if sameAlgorithm.isEmpty {
                        mergedBindings.append(incoming)
                    }
                    fingerprints.insert(incoming.fingerprint)
                }
                candidateCache[candidate] = StoredPeer(
                    fingerprints: Array(fingerprints).sorted(),
                    keyBindings: normalizedBindings(mergedBindings),
                    conflictedAlgorithms: existing?.conflictedAlgorithms,
                    updatedAt: observedAt
                )
            }
            let receipt = AuthorityBoundMutationReceipt(
                entries: Set(candidates).sorted().compactMap { candidate in
                    let previous = previousCache[candidate]
                    let committed = candidateCache[candidate]
                    guard previous != committed else { return nil }
                    return AuthorityBoundEntryMutation(
                        deviceId: candidate,
                        previous: previous,
                        committed: committed,
                        algorithms: Set(bindings.map(\.algorithm))
                    )
                }
            )
            preparedMutations.append(
                PreparedAuthorityBoundMutation(
                    before: try snapshot(of: previousCache),
                    after: try snapshot(of: candidateCache),
                    receipt: receipt
                )
            )
            simulatedCache = candidateCache
        }
        return preparedMutations
    }

    func applyPreparedAuthorityBoundMutation(
        _ prepared: PreparedAuthorityBoundMutation,
        permitsJournal: Bool
    ) throws {
        try requirePersistenceBackingAvailable()
        if !permitsJournal, isAuthorityJournalQuarantined {
            throw AuthorityBoundUpdateError.authorityTransactionQuarantined
        }
        let before = try decodedCache(from: prepared.before)
        guard cache == before else {
            throw AuthorityBoundUpdateError.concurrentModification
        }
        let after = try decodedCache(from: prepared.after)
        try persist(after, permitsJournal: permitsJournal)
        cache = after
    }

    func currentAuthorityBoundSnapshotIgnoringJournal() throws -> AuthorityBoundSnapshot {
        try requirePersistenceBackingAvailable()
        return try snapshot(of: cache)
    }

    func restoreAuthorityBoundSnapshotIgnoringJournal(
        _ snapshot: AuthorityBoundSnapshot,
        expectedCurrent: [AuthorityBoundSnapshot]
    ) throws {
        try requirePersistenceBackingAvailable()
        let expectedCaches = try expectedCurrent.map { try decodedCache(from: $0) }
        guard expectedCaches.contains(cache) else {
            throw AuthorityBoundUpdateError.concurrentModification
        }
        let restored = try decodedCache(from: snapshot)
        try persist(restored, permitsJournal: true)
        cache = restored
    }

    func authorityBoundSnapshotMatchesIgnoringJournal(
        _ snapshot: AuthorityBoundSnapshot
    ) throws -> Bool {
        try requirePersistenceBackingAvailable()
        return cache == (try decodedCache(from: snapshot))
    }

    func rollbackAuthorityBoundMutation(
        _ receipt: AuthorityBoundMutationReceipt,
        permitsJournal: Bool = false
    ) throws {
        try requirePersistenceBackingAvailable()
        if !permitsJournal, isAuthorityJournalQuarantined {
            throw AuthorityBoundUpdateError.authorityTransactionQuarantined
        }
        var candidateCache = cache
        for entry in receipt.entries {
            for algorithm in entry.algorithms {
                let currentMatchesCommitted = authorityBoundAlgorithm(
                    algorithm,
                    in: candidateCache[entry.deviceId],
                    matches: entry.committed
                )
                let currentMatchesPrevious = authorityBoundAlgorithm(
                    algorithm,
                    in: candidateCache[entry.deviceId],
                    matches: entry.previous
                )
                guard currentMatchesCommitted || currentMatchesPrevious else {
                    throw AuthorityBoundUpdateError.concurrentModification
                }
            }
        }
        for entry in receipt.entries {
            let algorithmsToRollback = entry.algorithms.filter { algorithm in
                authorityBoundAlgorithm(
                    algorithm,
                    in: candidateCache[entry.deviceId],
                    matches: entry.committed
                ) && !authorityBoundAlgorithm(
                    algorithm,
                    in: entry.committed,
                    matches: entry.previous
                )
            }
            guard !algorithmsToRollback.isEmpty else { continue }
            guard var current = candidateCache[entry.deviceId] else {
                throw AuthorityBoundUpdateError.concurrentModification
            }
            let currentWasExactCommitted = current == entry.committed
            let previousBindings = normalizedBindings(entry.previous?.keyBindings)
            let committedBindings = normalizedBindings(entry.committed?.keyBindings)
            var mergedBindings = normalizedBindings(current.keyBindings).filter {
                !algorithmsToRollback.contains($0.algorithm)
            }
            mergedBindings.append(contentsOf: previousBindings.filter {
                algorithmsToRollback.contains($0.algorithm)
            })
            current.keyBindings = normalizedBindings(mergedBindings)

            var fingerprints = Set(current.fingerprints)
            let committedFingerprints = Set(committedBindings.filter {
                algorithmsToRollback.contains($0.algorithm)
            }.map(\.fingerprint))
            let previousFingerprints = Set(previousBindings.filter {
                algorithmsToRollback.contains($0.algorithm)
            }.map(\.fingerprint))
            let survivingBindingFingerprints = Set(
                normalizedBindings(current.keyBindings).map(\.fingerprint)
            )
            for fingerprint in committedFingerprints.subtracting(previousFingerprints)
            where !survivingBindingFingerprints.contains(fingerprint) {
                fingerprints.remove(fingerprint)
            }
            fingerprints.formUnion(previousFingerprints)
            current.fingerprints = Array(fingerprints).sorted()

            var conflictedAlgorithms = Set(current.conflictedAlgorithms ?? [])
            let previousConflictedAlgorithms = Set(
                entry.previous?.conflictedAlgorithms ?? []
            )
            for algorithm in algorithmsToRollback {
                if previousConflictedAlgorithms.contains(algorithm) {
                    conflictedAlgorithms.insert(algorithm)
                } else {
                    conflictedAlgorithms.remove(algorithm)
                }
            }
            current.conflictedAlgorithms = conflictedAlgorithms.isEmpty
                ? nil
                : Array(conflictedAlgorithms).sorted()
            if current.updatedAt == entry.committed?.updatedAt,
               let previousUpdatedAt = entry.previous?.updatedAt {
                current.updatedAt = previousUpdatedAt
            }

            if entry.previous == nil,
               currentWasExactCommitted,
               current.keyBindings?.isEmpty != false,
               current.fingerprints.isEmpty,
               current.conflictedAlgorithms?.isEmpty != false {
                candidateCache.removeValue(forKey: entry.deviceId)
            } else {
                candidateCache[entry.deviceId] = current
            }
        }
        if candidateCache != cache {
            try persist(candidateCache, permitsJournal: permitsJournal)
            cache = candidateCache
        }
    }

    func rollForwardAuthorityBoundMutation(
        _ receipt: AuthorityBoundMutationReceipt,
        permitsJournal: Bool = false
    ) throws {
        try requirePersistenceBackingAvailable()
        if !permitsJournal, isAuthorityJournalQuarantined {
            throw AuthorityBoundUpdateError.authorityTransactionQuarantined
        }
        var candidateCache = cache
        for entry in receipt.entries {
            for algorithm in entry.algorithms {
                let currentMatchesPrevious = authorityBoundAlgorithm(
                    algorithm,
                    in: candidateCache[entry.deviceId],
                    matches: entry.previous
                )
                let currentMatchesCommitted = authorityBoundAlgorithm(
                    algorithm,
                    in: candidateCache[entry.deviceId],
                    matches: entry.committed
                )
                guard currentMatchesPrevious || currentMatchesCommitted else {
                    throw AuthorityBoundUpdateError.concurrentModification
                }
            }
        }

        for entry in receipt.entries {
            if candidateCache[entry.deviceId] == entry.previous,
               entry.previous != entry.committed {
                if let committed = entry.committed {
                    candidateCache[entry.deviceId] = committed
                } else {
                    candidateCache.removeValue(forKey: entry.deviceId)
                }
                continue
            }
            let algorithmsToApply = entry.algorithms.filter { algorithm in
                authorityBoundAlgorithm(
                    algorithm,
                    in: candidateCache[entry.deviceId],
                    matches: entry.previous
                ) && !authorityBoundAlgorithm(
                    algorithm,
                    in: entry.committed,
                    matches: entry.previous
                )
            }
            guard !algorithmsToApply.isEmpty else { continue }
            guard var current = candidateCache[entry.deviceId] else {
                guard let committed = entry.committed else {
                    throw AuthorityBoundUpdateError.concurrentModification
                }
                candidateCache[entry.deviceId] = committed
                continue
            }
            let previousBindings = normalizedBindings(entry.previous?.keyBindings)
            let committedBindings = normalizedBindings(entry.committed?.keyBindings)
            var mergedBindings = normalizedBindings(current.keyBindings).filter {
                !algorithmsToApply.contains($0.algorithm)
            }
            mergedBindings.append(contentsOf: committedBindings.filter {
                algorithmsToApply.contains($0.algorithm)
            })
            current.keyBindings = normalizedBindings(mergedBindings)

            var fingerprints = Set(current.fingerprints)
            let previousFingerprints = Set(previousBindings.filter {
                algorithmsToApply.contains($0.algorithm)
            }.map(\.fingerprint))
            let committedFingerprints = Set(committedBindings.filter {
                algorithmsToApply.contains($0.algorithm)
            }.map(\.fingerprint))
            let survivingBindingFingerprints = Set(
                normalizedBindings(current.keyBindings).map(\.fingerprint)
            )
            for fingerprint in previousFingerprints.subtracting(committedFingerprints)
            where !survivingBindingFingerprints.contains(fingerprint) {
                fingerprints.remove(fingerprint)
            }
            fingerprints.formUnion(committedFingerprints)
            current.fingerprints = Array(fingerprints).sorted()

            var conflictedAlgorithms = Set(current.conflictedAlgorithms ?? [])
            let committedConflictedAlgorithms = Set(
                entry.committed?.conflictedAlgorithms ?? []
            )
            for algorithm in algorithmsToApply {
                if committedConflictedAlgorithms.contains(algorithm) {
                    conflictedAlgorithms.insert(algorithm)
                } else {
                    conflictedAlgorithms.remove(algorithm)
                }
            }
            current.conflictedAlgorithms = conflictedAlgorithms.isEmpty
                ? nil
                : Array(conflictedAlgorithms).sorted()
            if current.updatedAt == entry.previous?.updatedAt,
               let committedUpdatedAt = entry.committed?.updatedAt {
                current.updatedAt = committedUpdatedAt
            }
            candidateCache[entry.deviceId] = current
        }
        if candidateCache != cache {
            try persist(candidateCache, permitsJournal: permitsJournal)
            cache = candidateCache
        }
    }

    func authorityBoundMutationMatchesCommittedIgnoringJournal(
        _ receipt: AuthorityBoundMutationReceipt
    ) throws -> Bool {
        try requirePersistenceBackingAvailable()
        return authorityBoundMutation(receipt, matchesCommitted: true)
    }

    func authorityBoundMutationMatchesRolledBackIgnoringJournal(
        _ receipt: AuthorityBoundMutationReceipt
    ) throws -> Bool {
        try requirePersistenceBackingAvailable()
        return authorityBoundMutation(receipt, matchesCommitted: false)
    }

    private func authorityBoundMutation(
        _ receipt: AuthorityBoundMutationReceipt,
        matchesCommitted: Bool
    ) -> Bool {
        receipt.entries.allSatisfy { entry in
            entry.algorithms.allSatisfy { algorithm in
                authorityBoundAlgorithm(
                    algorithm,
                    in: cache[entry.deviceId],
                    matches: matchesCommitted ? entry.committed : entry.previous
                )
            }
        }
    }

    private func authorityBoundAlgorithm(
        _ algorithm: String,
        in current: StoredPeer?,
        matches expected: StoredPeer?
    ) -> Bool {
        let currentBindings = normalizedBindings(current?.keyBindings).filter {
            $0.algorithm == algorithm
        }
        let expectedBindings = normalizedBindings(expected?.keyBindings).filter {
            $0.algorithm == algorithm
        }
        let currentIsConflicted = Set(current?.conflictedAlgorithms ?? []).contains(algorithm)
        let expectedIsConflicted = Set(expected?.conflictedAlgorithms ?? []).contains(algorithm)
        return currentBindings == expectedBindings
            && currentIsConflicted == expectedIsConflicted
    }

    public func upsert(deviceId: String, fingerprints: Set<String>) {
        guard persistenceAvailable, !isAuthorityJournalQuarantined else { return }
        let previousCache = cache
        let candidates = Self.trustMaterialCandidates(forAny: [deviceId])
        let normalizedFingerprints = Set(fingerprints.compactMap(Self.normalizedFingerprint))
        guard !candidates.isEmpty, !normalizedFingerprints.isEmpty else { return }

        let observedAt = Date()
        let merged = Array(normalizedFingerprints).sorted()
        for candidate in candidates {
            let existing = Set(cache[candidate]?.fingerprints ?? [])
            cache[candidate] = StoredPeer(
                fingerprints: Array(existing.union(merged)).sorted(),
                keyBindings: cache[candidate]?.keyBindings,
                conflictedAlgorithms: cache[candidate]?.conflictedAlgorithms,
                updatedAt: observedAt
            )
        }
        save(restoring: previousCache)
    }

    public func trustedFingerprints(for deviceId: String) -> Set<String> {
        trustedFingerprints(forAny: [deviceId])
    }

    public func trustedFingerprints(forAny deviceIds: [String]) -> Set<String> {
        guard persistenceAvailable, !isAuthorityJournalQuarantined else { return [] }
        var fingerprints = Set<String>()
        for candidate in Self.trustMaterialCandidates(forAny: deviceIds) {
            guard let stored = cache[candidate] else { continue }
            guard stored.conflictedAlgorithms?.isEmpty != false else { continue }
            fingerprints.formUnion(stored.fingerprints.compactMap(Self.normalizedFingerprint))
        }
        return fingerprints
    }

    public func deviceIds(containingFingerprint rawFingerprint: String) -> [String] {
        guard persistenceAvailable, !isAuthorityJournalQuarantined else { return [] }
        guard let fingerprint = Self.normalizedFingerprint(rawFingerprint) else { return [] }
        return cache.compactMap { deviceId, stored in
            guard PeerIdentityAliasResolver.persistentDeviceId(from: deviceId) != nil else {
                return nil
            }
            guard stored.conflictedAlgorithms?.isEmpty != false else { return nil }
            return stored.fingerprints.contains(fingerprint) ? deviceId : nil
        }
        .sorted()
    }

    public func clear(deviceId: String) {
        guard persistenceAvailable, !isAuthorityJournalQuarantined else { return }
        let previousCache = cache
        for candidate in Self.trustMaterialCandidates(forAny: [deviceId]) {
            cache.removeValue(forKey: candidate)
        }
        save(restoring: previousCache)
    }

#if DEBUG || SKYBRIDGE_TESTING
    public func clearForTesting() {
        guard !isAuthorityJournalQuarantined else { return }
        let previousCache = cache
        cache.removeAll()
        persistenceAvailable = true
        save(restoring: previousCache)
    }

    func testOnlyStoredPeerCount() -> Int {
        cache.count
    }
#endif

    public func trustedProtocolIdentityPublicKey(
        forAny deviceIds: [String],
        algorithm: ProtocolSigningAlgorithm
    ) -> Data? {
        guard persistenceAvailable, !isAuthorityJournalQuarantined else { return nil }
        var uniqueKeys = Set<Data>()
        for candidate in Self.trustMaterialCandidates(forAny: deviceIds) {
            guard let stored = cache[candidate],
                  stored.conflictedAlgorithms?.isEmpty != false else {
                continue
            }
            for binding in normalizedBindings(stored.keyBindings)
            where binding.algorithm == algorithm.rawValue {
                guard let publicKey = binding.publicKeyBytes else { continue }
                uniqueKeys.insert(publicKey)
            }
        }
        guard uniqueKeys.count == 1 else { return nil }
        return uniqueKeys.first
    }

    private func upsert(deviceId: String, bindings: [StoredKeyBinding]) {
        guard persistenceAvailable, !isAuthorityJournalQuarantined else { return }
        let previousCache = cache
        let candidates = Self.trustMaterialCandidates(forAny: [deviceId])
        let normalizedIncoming = normalizedBindings(bindings)
        guard !candidates.isEmpty, !normalizedIncoming.isEmpty else { return }

        let observedAt = Date()
        for candidate in candidates {
            let existing = cache[candidate]
            var mergedBindings = normalizedBindings(existing?.keyBindings)
            var conflictedAlgorithms = Set(existing?.conflictedAlgorithms ?? [])
            var fingerprints = Set(existing?.fingerprints.compactMap(Self.normalizedFingerprint) ?? [])

            for incoming in normalizedIncoming {
                let sameAlgorithm = mergedBindings.filter { $0.algorithm == incoming.algorithm }
                if sameAlgorithm.contains(where: {
                    $0.fingerprint != incoming.fingerprint
                        || $0.publicKeyBase64 != incoming.publicKeyBase64
                }) {
                    conflictedAlgorithms.insert(incoming.algorithm)
                    continue
                }
                if sameAlgorithm.isEmpty {
                    mergedBindings.append(incoming)
                }
                fingerprints.insert(incoming.fingerprint)
            }

            cache[candidate] = StoredPeer(
                fingerprints: Array(fingerprints).sorted(),
                keyBindings: normalizedBindings(mergedBindings),
                conflictedAlgorithms: conflictedAlgorithms.isEmpty
                    ? nil
                    : Array(conflictedAlgorithms).sorted(),
                updatedAt: observedAt
            )
        }
        save(restoring: previousCache)
    }

    private func normalizedBindings(_ bindings: [StoredKeyBinding]?) -> [StoredKeyBinding] {
        var byIdentity: [String: StoredKeyBinding] = [:]
        for binding in bindings ?? [] {
            guard binding.schemaVersion == StoredKeyBinding.currentSchemaVersion,
                  let algorithm = ProtocolSigningAlgorithm(rawValue: binding.algorithm),
                  let fingerprint = Self.normalizedFingerprint(binding.fingerprint),
                  let publicKey = binding.publicKeyBytes,
                  Self.hasValidPublicKeyLength(publicKey, algorithm: algorithm),
                  AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: algorithm.rawValue,
                    publicKey: publicKey
                  ).authoritativeFingerprint == fingerprint else {
                continue
            }
            let normalized = StoredKeyBinding(
                key: AppMessage.ProtocolIdentityPublicKeyInfo(
                    protocolSigningAlgorithm: algorithm.rawValue,
                    publicKey: publicKey
                ),
                fingerprint: fingerprint
            )
            byIdentity[
                [normalized.algorithm, normalized.fingerprint, normalized.publicKeyBase64]
                    .joined(separator: "\u{0}")
            ] = normalized
        }
        return byIdentity.values.sorted {
            if $0.algorithm != $1.algorithm { return $0.algorithm < $1.algorithm }
            return $0.fingerprint < $1.fingerprint
        }
    }

    private static func hasValidPublicKeyLength(
        _ publicKey: Data,
        algorithm: ProtocolSigningAlgorithm
    ) -> Bool {
        switch algorithm {
        case .ed25519: return publicKey.count == 32
        case .mlDSA65: return publicKey.count == 1_952
        case .mlDSA87: return publicKey.count == 2_592
        }
    }

    private static func normalizedFingerprint(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.count == 64, value.allSatisfy(\.isHexDigit) else { return nil }
        return value
    }

    private static func lookupCandidates(forAny identifiers: [String]) -> [String] {
        var ordered: [String] = []
        var seen = Set<String>()

        func append(_ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return }
            ordered.append(trimmed)
        }

        for identifier in identifiers {
            for candidate in PeerIdentityAliasResolver.lookupCandidates(for: identifier)
            where PeerIdentityAliasResolver.persistentDeviceId(from: candidate) != nil {
                append(candidate)
            }
        }

        return ordered
    }

    private static func trustMaterialCandidates(forAny identifiers: [String]) -> [String] {
        lookupCandidates(forAny: identifiers)
    }

    private static func authorityBoundTrustMaterialCandidates(
        forAny identifiers: [String]
    ) -> [String] {
        let persistentIdentifiers = identifiers.compactMap {
            PeerIdentityAliasResolver.authorityBoundPersistentDeviceId(from: $0)
        }
        return trustMaterialCandidates(forAny: persistentIdentifiers)
    }

    private static func loadCache(
        storageKey: String,
        userDefaults: UserDefaults
    ) throws -> [String: StoredPeer] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        let decoded = try JSONDecoder().decode([String: StoredPeer].self, from: data)
        return Dictionary(
            uniqueKeysWithValues: decoded.compactMap { deviceId, peer in
                guard let normalizedDeviceId = PeerIdentityAliasResolver.normalizedIdentifier(deviceId),
                      normalizedDeviceId == deviceId,
                      PeerIdentityAliasResolver.persistentDeviceId(from: normalizedDeviceId) != nil else {
                    return nil
                }
                return (normalizedDeviceId, peer)
            }
        )
    }

    private func persist(
        _ candidateCache: [String: StoredPeer],
        permitsJournal: Bool = false
    ) throws {
        try requirePersistenceBackingAvailable()
        if !permitsJournal, isAuthorityJournalQuarantined {
            throw AuthorityBoundUpdateError.authorityTransactionQuarantined
        }
        let previousData = userDefaults.data(forKey: storageKey)
        let data: Data
        do {
            data = try JSONEncoder().encode(candidateCache)
        } catch {
            throw AuthorityBoundUpdateError.encodingFailed(error.localizedDescription)
        }
        userDefaults.set(data, forKey: storageKey)
        guard userDefaults.data(forKey: storageKey) == data else {
            if let previousData {
                userDefaults.set(previousData, forKey: storageKey)
            } else {
                userDefaults.removeObject(forKey: storageKey)
            }
            throw AuthorityBoundUpdateError.writeVerificationFailed
        }
    }

    private func requirePersistenceAvailable(
        outerPermit: PairingIdentityAuthorityMutationPermit? = nil
    ) throws {
        try requirePersistenceBackingAvailable()
        guard !authorityJournalExists() else {
            throw AuthorityBoundUpdateError.authorityTransactionQuarantined
        }
        if pairingAcceptanceJournalExists() {
            guard let outerPermit,
                  PairingAcceptanceJournalStore.permitOwnsActiveJournal(outerPermit) else {
                throw AuthorityBoundUpdateError.authorityTransactionQuarantined
            }
        }
    }

    private func requirePersistenceBackingAvailable() throws {
        guard persistenceAvailable else {
            throw AuthorityBoundUpdateError.persistenceUnavailable
        }
    }

    private var isAuthorityJournalQuarantined: Bool {
        authorityJournalExists() || pairingAcceptanceJournalExists()
    }

    private func snapshot(
        of candidateCache: [String: StoredPeer]
    ) throws -> AuthorityBoundSnapshot {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return AuthorityBoundSnapshot(encodedCache: try encoder.encode(candidateCache))
        } catch {
            throw AuthorityBoundUpdateError.encodingFailed(error.localizedDescription)
        }
    }

    private func decodedCache(
        from snapshot: AuthorityBoundSnapshot
    ) throws -> [String: StoredPeer] {
        do {
            return try JSONDecoder().decode(
                [String: StoredPeer].self,
                from: snapshot.encodedCache
            )
        } catch {
            throw AuthorityBoundUpdateError.encodingFailed(
                "Invalid journal snapshot: \(error.localizedDescription)"
            )
        }
    }

    private func save(restoring previousCache: [String: StoredPeer]) {
        do {
            try persist(cache)
        } catch {
            cache = previousCache
            if (error as? AuthorityBoundUpdateError) != .authorityTransactionQuarantined {
                persistenceAvailable = false
            }
            SkyBridgeLogger.shared.error(
                "⛔️ Protocol identity trust persistence failed: \(error.localizedDescription)"
            )
        }
    }
}
