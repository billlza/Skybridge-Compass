import Foundation
import CryptoKit

/// Stores peer KEM identity public keys by deviceId.
/// This is the missing prerequisite for negotiating PQC suites (initiator needs peer KEM public key).
@available(iOS 17.0, *)
public actor KEMTrustStore {
    public static let shared = KEMTrustStore()

    public enum SignedRefreshImportError: Error, LocalizedError, Sendable, Equatable {
        case signatureVerificationFailed
        case signatureVerificationError(String)
        case qPeriaptPlatformMetadataUnavailable

        public var errorDescription: String? {
            switch self {
            case .signatureVerificationFailed:
                return "SKR-1 signature verification failed at KEM trust store import"
            case .signatureVerificationError(let detail):
                return "SKR-1 signature verification error at KEM trust store import: \(detail)"
            case .qPeriaptPlatformMetadataUnavailable:
                return "SKR-1 cannot import Q-Periapt until peer platform metadata is signature-bound"
            }
        }
    }

    private struct StoredPeer: Codable, Sendable {
        var keys: [UInt16: Data] // suiteWireId -> publicKey
        var updatedAt: Date
        var platform: String? = nil
        var osVersion: String? = nil
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

    public func upsert(
        deviceId: String,
        kemPublicKeys: [KEMPublicKeyInfo],
        platform: String? = nil,
        osVersion: String? = nil
    ) {
        let candidates = Self.trustMaterialCandidates(forAny: [deviceId])
        guard !candidates.isEmpty else { return }
        let incomingPlatform = Self.normalizedPeerMetadata(platform)
        let incomingOSVersion = Self.normalizedPeerMetadata(osVersion)
        let validKeys = KEMPublicKeyInfo.normalizedValidKeys(
            kemPublicKeys,
            platform: incomingPlatform,
            osVersion: incomingOSVersion
        )
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
            let qPeriaptWireID = CryptoSuite.qperiaptABI2PolicyBound.wireId
            let incomingContainsQPeriapt = validKeys.contains {
                $0.suiteWireId == qPeriaptWireID
            }
            let retainedExistingQPeriapt = existingKeys[qPeriaptWireID] != nil
            let storedPlatform: String?
            let storedOSVersion: String?
            if incomingContainsQPeriapt {
                storedPlatform = incomingPlatform
                storedOSVersion = incomingOSVersion
            } else if retainedExistingQPeriapt {
                storedPlatform = existing?.platform
                storedOSVersion = existing?.osVersion
            } else {
                storedPlatform = nil
                storedOSVersion = nil
            }
            cache[candidate] = StoredPeer(
                keys: dict,
                updatedAt: observedAt,
                platform: storedPlatform,
                osVersion: storedOSVersion,
                source: "pairing_identity_exchange"
            )
        }
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
        guard !validPayload.kemPublicKeys.contains(where: {
            $0.suiteWireId == CryptoSuite.qperiaptABI2PolicyBound.wireId
        }) else {
            throw SignedRefreshImportError.qPeriaptPlatformMetadataUnavailable
        }
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
                platform: nil,
                osVersion: nil,
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
            for (suiteWireId, publicKey) in Self.sanitizedKEMMap(
                peer.keys,
                platform: peer.platform,
                osVersion: peer.osVersion
            )
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

    private func selectKEMPublicKeys(for deviceIds: [String]) -> [CryptoSuite: SelectedKey] {
        let candidates = Self.trustMaterialCandidates(forAny: deviceIds)
        let canonicalCandidates = Self.canonicalLookupCandidates(for: deviceIds)
        var selected: [CryptoSuite: SelectedKey] = [:]

        for (index, candidate) in candidates.enumerated() {
            guard let stored = cache[candidate] else { continue }
            if let expiresAt = stored.expiresAt, expiresAt <= Date() { continue }
            let isCanonical = canonicalCandidates.contains(candidate)
            let signedSuiteWireIds = Set(stored.signedSuiteWireIds ?? (stored.source == "signed_lan_kem_refresh" ? Array(stored.keys.keys) : []))
            for (wireId, pk) in Self.sanitizedKEMMap(
                stored.keys,
                platform: stored.platform,
                osVersion: stored.osVersion
            ) {
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

        var mergedKeys: [
            UInt16: (
                publicKey: Data,
                updatedAt: Date,
                isCanonical: Bool,
                isSignedRefresh: Bool,
                platform: String?,
                osVersion: String?
            )
        ] = [:]
        var selectedSignedEvidence: StoredPeer?
        for candidate in migrationCandidates {
            guard let stored = cache[candidate] else { continue }
            let isCanonicalCandidate = canonicalCandidates.contains(candidate)
            let sanitizedKeys = Self.sanitizedKEMMap(
                stored.keys,
                platform: stored.platform,
                osVersion: stored.osVersion
            )
            let signedSuiteWireIds = Set(stored.signedSuiteWireIds ?? (stored.source == "signed_lan_kem_refresh" ? Array(sanitizedKeys.keys) : []))
            if stored.source == "signed_lan_kem_refresh",
               stored.expiresAt.map({ $0 > Date() }) ?? true,
               !sanitizedKeys.isEmpty,
               selectedSignedEvidence.map({ stored.updatedAt > $0.updatedAt }) ?? true {
                selectedSignedEvidence = stored
            }
            for (wireId, publicKey) in sanitizedKeys {
                let isSignedRefresh = stored.source == "signed_lan_kem_refresh" && signedSuiteWireIds.contains(wireId)
                if let existing = mergedKeys[wireId] {
                    if isSignedRefresh != existing.isSignedRefresh {
                        if isSignedRefresh {
                            mergedKeys[wireId] = (
                                publicKey,
                                stored.updatedAt,
                                isCanonicalCandidate,
                                isSignedRefresh,
                                stored.platform,
                                stored.osVersion
                            )
                        }
                    } else if stored.updatedAt > existing.updatedAt
                        || (stored.updatedAt == existing.updatedAt
                            && isCanonicalCandidate
                            && !existing.isCanonical) {
                        mergedKeys[wireId] = (
                            publicKey,
                            stored.updatedAt,
                            isCanonicalCandidate,
                            isSignedRefresh,
                            stored.platform,
                            stored.osVersion
                        )
                    }
                } else {
                    mergedKeys[wireId] = (
                        publicKey,
                        stored.updatedAt,
                        isCanonicalCandidate,
                        isSignedRefresh,
                        stored.platform,
                        stored.osVersion
                    )
                }
            }
        }
        guard !mergedKeys.isEmpty else { return }

        let reboundSignedSuiteWireIds = selectedSignedEvidence
            .map { evidence in
                Set(
                    evidence.signedSuiteWireIds
                        ?? Self.sanitizedKEMMap(
                            evidence.keys,
                            platform: evidence.platform,
                            osVersion: evidence.osVersion
                        ).keys.sorted()
                )
                    .filter { mergedKeys[$0] != nil }
                    .sorted()
            }
        let qPeriaptMetadata = mergedKeys[CryptoSuite.qperiaptABI2PolicyBound.wireId]
        let rebound = StoredPeer(
            keys: Dictionary(uniqueKeysWithValues: mergedKeys.map { ($0.key, $0.value.publicKey) }),
            updatedAt: mergedKeys.values.map(\.updatedAt).max() ?? Date(),
            platform: qPeriaptMetadata?.platform,
            osVersion: qPeriaptMetadata?.osVersion,
            source: selectedSignedEvidence?.source,
            keyId: selectedSignedEvidence?.keyId,
            generation: selectedSignedEvidence?.generation,
            expiresAt: selectedSignedEvidence?.expiresAt,
            protocolIdentityFingerprint: selectedSignedEvidence?.protocolIdentityFingerprint,
            signingFingerprint: selectedSignedEvidence?.signingFingerprint,
            payloadHashHex: selectedSignedEvidence?.payloadHashHex,
            signedSuiteWireIds: reboundSignedSuiteWireIds,
            signedRefreshDeviceId: selectedSignedEvidence?.signedRefreshDeviceId
        )
        for candidate in Set(migrationCandidates) where !canonicalCandidates.contains(candidate) {
            cache.removeValue(forKey: candidate)
        }
        for candidate in canonicalCandidates {
            cache[candidate] = rebound
        }
        save()
    }

#if DEBUG
    public func clearForTesting() {
        cache.removeAll()
        save()
    }
#endif

    private static func loadCache(storageKey: String, userDefaults: UserDefaults) -> [String: StoredPeer] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        let decoded: [String: StoredPeer]
        do {
            decoded = try JSONDecoder().decode([String: StoredPeer].self, from: data)
        } catch {
            SkyBridgeLogger.shared.error("KEM trust store snapshot decode failed; refusing unverified persisted keys")
            return [:]
        }
        let sanitized = decoded.compactMapValues(Self.sanitizedPeer)
        do {
            userDefaults.set(try JSONEncoder().encode(sanitized), forKey: storageKey)
        } catch {
            SkyBridgeLogger.shared.error("KEM trust store sanitized snapshot could not be persisted")
        }
        return sanitized
    }

    private static func sanitizedPeer(_ peer: StoredPeer) -> StoredPeer? {
        var sanitized = peer
        sanitized.keys = sanitizedKEMMap(
            peer.keys,
            platform: peer.platform,
            osVersion: peer.osVersion
        )
        guard !sanitized.keys.isEmpty else { return nil }
        if let signedSuiteWireIds = sanitized.signedSuiteWireIds {
            sanitized.signedSuiteWireIds = signedSuiteWireIds
                .filter { sanitized.keys[$0] != nil }
                .sorted()
        }
        return sanitized
    }

    private static func sanitizedKEMMap(
        _ keys: [UInt16: Data],
        platform: String?,
        osVersion: String?
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

    private static func normalizedPeerMetadata(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= 128,
              !value.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            return nil
        }
        return value
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
        do {
            userDefaults.set(try JSONEncoder().encode(cache), forKey: storageKey)
        } catch {
            SkyBridgeLogger.shared.error("KEM trust store snapshot could not be persisted")
        }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Stores authenticated protocol-signing identity fingerprints advertised by a
/// peer inside an already established P2P/WebRTC session.
@available(iOS 17.0, *)
public actor ProtocolIdentityTrustStore {
    public static let shared = ProtocolIdentityTrustStore()

    private struct StoredPeer: Codable, Sendable {
        var fingerprints: [String]
        var updatedAt: Date
    }

    private let storageKey: String
    private let userDefaults: UserDefaults
    private var cache: [String: StoredPeer] = [:]

    init(
        storageKey: String = "protocol_identity_trust_store.v1",
        userDefaults: UserDefaults = .standard
    ) {
        self.storageKey = storageKey
        self.userDefaults = userDefaults
        cache = Self.loadCache(storageKey: storageKey, userDefaults: userDefaults)
    }

    public func upsert(
        deviceId: String,
        protocolIdentityPublicKeys: [AppMessage.ProtocolIdentityPublicKeyInfo]?
    ) {
        let fingerprints = Set((AppMessage.ProtocolIdentityPublicKeyInfo.normalizedValidKeys(protocolIdentityPublicKeys) ?? [])
            .compactMap { Self.normalizedFingerprint($0.authoritativeFingerprint) })
        upsert(deviceId: deviceId, fingerprints: fingerprints)
    }

    public func upsert(deviceId: String, fingerprints: Set<String>) {
        let candidates = Self.trustMaterialCandidates(forAny: [deviceId])
        let normalizedFingerprints = Set(fingerprints.compactMap(Self.normalizedFingerprint))
        guard !candidates.isEmpty, !normalizedFingerprints.isEmpty else { return }

        let observedAt = Date()
        let merged = Array(normalizedFingerprints).sorted()
        for candidate in candidates {
            let existing = Set(cache[candidate]?.fingerprints ?? [])
            cache[candidate] = StoredPeer(
                fingerprints: Array(existing.union(merged)).sorted(),
                updatedAt: observedAt
            )
        }
        save()
    }

    public func trustedFingerprints(for deviceId: String) -> Set<String> {
        trustedFingerprints(forAny: [deviceId])
    }

    public func trustedFingerprints(forAny deviceIds: [String]) -> Set<String> {
        var fingerprints = Set<String>()
        for candidate in Self.trustMaterialCandidates(forAny: deviceIds) {
            guard let stored = cache[candidate] else { continue }
            fingerprints.formUnion(stored.fingerprints.compactMap(Self.normalizedFingerprint))
        }
        return fingerprints
    }

    public func deviceIds(containingFingerprint rawFingerprint: String) -> [String] {
        guard let fingerprint = Self.normalizedFingerprint(rawFingerprint) else { return [] }
        return cache.compactMap { deviceId, stored in
            stored.fingerprints.contains(fingerprint) ? deviceId : nil
        }
        .sorted()
    }

    public func clear(deviceId: String) {
        for candidate in Self.trustMaterialCandidates(forAny: [deviceId]) {
            cache.removeValue(forKey: candidate)
        }
        save()
    }

#if DEBUG
    public func clearForTesting() {
        cache.removeAll()
        save()
    }
#endif

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

    private static func loadCache(storageKey: String, userDefaults: UserDefaults) -> [String: StoredPeer] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: StoredPeer].self, from: data)) ?? [:]
    }

    private func save() {
        let data = (try? JSONEncoder().encode(cache)) ?? Data()
        userDefaults.set(data, forKey: storageKey)
    }
}
