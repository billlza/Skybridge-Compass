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

    private struct StoredPeer: Codable, Sendable {
        struct AuthorityBoundBootstrap: Codable, Sendable {
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
        var signedSuiteWireIds: [UInt16]? = nil
        var signedRefreshDeviceId: String? = nil
        var authorityBoundBootstraps: [String: AuthorityBoundBootstrap]? = nil
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
        public let updatedAt: Date
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
        save()
    }

    /// Imports join/bootstrap KEM material only after its protocol identity has
    /// been validated and pinned by the current-path admission transaction.
    /// This is intentionally separate from the legacy pairing upsert: strict
    /// handshake lookup can distinguish authority-bound bootstrap keys from
    /// unbound discovery material.
    public func upsertAuthorityBoundBootstrap(
        deviceIds: [String],
        kemPublicKeys: [KEMPublicKeyInfo],
        verifiedProtocolFingerprint: String
    ) throws {
        guard let fingerprint = Self.normalizedFingerprint(verifiedProtocolFingerprint) else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Authority-bound KEM bootstrap has an invalid protocol fingerprint"
            )
        }
        let candidates = Self.trustMaterialCandidates(forAny: deviceIds)
        let validKeys = KEMPublicKeyInfo.normalizedValidKeys(kemPublicKeys)
        guard !candidates.isEmpty, !validKeys.isEmpty else {
            throw SkyBridgeError.invalidKeyData(
                reason: "Authority-bound KEM bootstrap has no valid peer or KEM key"
            )
        }

        let observedAt = Date()
        let keyDict = Dictionary(uniqueKeysWithValues: validKeys.map { ($0.suiteWireId, $0.publicKey) })
        for candidate in candidates {
            if var existing = cache[candidate] {
                var bootstraps = existing.authorityBoundBootstraps ?? [:]
                bootstraps[fingerprint] = StoredPeer.AuthorityBoundBootstrap(
                    keys: keyDict,
                    updatedAt: observedAt
                )
                existing.authorityBoundBootstraps = Self.prunedAuthorityBoundBootstraps(
                    bootstraps
                )
                existing.updatedAt = max(existing.updatedAt, observedAt)
                cache[candidate] = existing
            } else {
                cache[candidate] = StoredPeer(
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
        pruneCacheIfNeeded()
        save()
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
        let candidates = Self.trustMaterialCandidates(forAny: identifiers)
        guard !candidates.isEmpty else { return }

        let keyDict = Dictionary(uniqueKeysWithValues: validKeys.map { ($0.suiteWireId, $0.publicKey) })
        let payloadHash = Self.sha256Hex(validPayload.signaturePreimage)
        let observedAt = Date()
        for candidate in candidates {
            cache[candidate] = StoredPeer(
                keys: keyDict,
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
        pruneCacheIfNeeded()
        save()
    }

    public func kemPublicKeys(for deviceId: String) -> [CryptoSuite: Data] {
        kemPublicKeys(forAny: [deviceId])
    }

    public func kemPublicKeys(forAny deviceIds: [String]) -> [CryptoSuite: Data] {
        Dictionary(
            uniqueKeysWithValues: selectKEMPublicKeys(for: deviceIds).map { suite, selected in
                (suite, selected.publicKey)
            }
        )
    }

    public func signedRefreshKEMPublicKeys(
        forAny deviceIds: [String],
        pinnedProtocolFingerprints: Set<String>
    ) -> [CryptoSuite: Data] {
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
        var maximum: UInt64?
        for candidate in Self.trustMaterialCandidates(forAny: deviceIds) {
            guard let generation = cache[candidate]?.generation else { continue }
            maximum = max(maximum ?? generation, generation)
        }
        return maximum
    }

    public func signedRefreshEvidence(forAny deviceIds: [String]) -> SignedRefreshEvidence? {
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
                updatedAt: stored.updatedAt
            )
            if selected.map({ evidence.updatedAt > $0.updatedAt }) ?? true {
                selected = evidence
            }
        }
        return selected
    }

    public func clear(deviceId: String) {
        for candidate in Self.trustMaterialCandidates(forAny: [deviceId]) {
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
        save()
    }

#if DEBUG || SKYBRIDGE_TESTING
    public func clearForTesting() {
        cache.removeAll()
        save()
    }
#endif

    private static func loadCache(storageKey: String, userDefaults: UserDefaults) -> [String: StoredPeer] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        let decoded = (try? JSONDecoder().decode([String: StoredPeer].self, from: data)) ?? [:]
        return decoded.compactMapValues(Self.sanitizedPeer)
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

        let normalized = trimmed.lowercased()
        if !PeerIdentityAliasResolver.isEndpointAlias(normalized) {
            append(normalized)
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
        lookupCandidates(forAny: identifiers).filter { !PeerIdentityAliasResolver.isEndpointAlias($0) }
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

    private func save() {
        let data = (try? JSONEncoder().encode(cache)) ?? Data()
        userDefaults.set(data, forKey: storageKey)
    }

    private func pruneCacheIfNeeded() {
        guard cache.count > Self.maximumStoredPeerAliases else { return }
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
        .prefix(cache.count - Self.maximumStoredPeerAliases) {
            cache.removeValue(forKey: candidate)
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Stores authenticated protocol-signing identity material advertised by a
/// peer inside an already established P2P/WebRTC session. Versioned raw-key
/// bindings are authoritative when present; legacy fingerprint-only rows stay
/// readable for migration but can never overwrite a raw binding.
@available(iOS 17.0, *)
public actor ProtocolIdentityTrustStore {
    public static let shared = ProtocolIdentityTrustStore()

    private struct StoredPeer: Codable, Sendable {
        var fingerprints: [String]
        var keyBindings: [StoredKeyBinding]?
        var conflictedAlgorithms: [String]?
        var updatedAt: Date
    }

    private struct StoredKeyBinding: Codable, Sendable, Equatable {
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
    private var cache: [String: StoredPeer] = [:]
    private var persistenceAvailable = true

    init(
        storageKey: String = "protocol_identity_trust_store.v1",
        userDefaults: UserDefaults = .standard
    ) {
        self.storageKey = storageKey
        self.userDefaults = userDefaults
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

    public func upsert(deviceId: String, fingerprints: Set<String>) {
        guard persistenceAvailable else { return }
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
        save()
    }

    public func trustedFingerprints(for deviceId: String) -> Set<String> {
        trustedFingerprints(forAny: [deviceId])
    }

    public func trustedFingerprints(forAny deviceIds: [String]) -> Set<String> {
        guard persistenceAvailable else { return [] }
        var fingerprints = Set<String>()
        for candidate in Self.trustMaterialCandidates(forAny: deviceIds) {
            guard let stored = cache[candidate] else { continue }
            guard stored.conflictedAlgorithms?.isEmpty != false else { continue }
            fingerprints.formUnion(stored.fingerprints.compactMap(Self.normalizedFingerprint))
        }
        return fingerprints
    }

    public func deviceIds(containingFingerprint rawFingerprint: String) -> [String] {
        guard persistenceAvailable else { return [] }
        guard let fingerprint = Self.normalizedFingerprint(rawFingerprint) else { return [] }
        return cache.compactMap { deviceId, stored in
            guard stored.conflictedAlgorithms?.isEmpty != false else { return nil }
            return stored.fingerprints.contains(fingerprint) ? deviceId : nil
        }
        .sorted()
    }

    public func clear(deviceId: String) {
        for candidate in Self.trustMaterialCandidates(forAny: [deviceId]) {
            cache.removeValue(forKey: candidate)
        }
        save()
    }

#if DEBUG || SKYBRIDGE_TESTING
    public func clearForTesting() {
        cache.removeAll()
        persistenceAvailable = true
        save()
    }
#endif

    public func trustedProtocolIdentityPublicKey(
        forAny deviceIds: [String],
        algorithm: ProtocolSigningAlgorithm
    ) -> Data? {
        guard persistenceAvailable else { return nil }
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
        guard persistenceAvailable else { return }
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
        save()
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
            where !PeerIdentityAliasResolver.isEndpointAlias(candidate) {
                append(candidate)
            }
        }

        return ordered
    }

    private static func trustMaterialCandidates(forAny identifiers: [String]) -> [String] {
        lookupCandidates(forAny: identifiers)
    }

    private static func loadCache(
        storageKey: String,
        userDefaults: UserDefaults
    ) throws -> [String: StoredPeer] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        return try JSONDecoder().decode([String: StoredPeer].self, from: data)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(cache)
            userDefaults.set(data, forKey: storageKey)
        } catch {
            persistenceAvailable = false
        }
    }
}
