import CryptoKit
import Foundation
import os

enum PQCIdentityTokenError: Error, Sendable, Equatable {
    case invalid
}

/// Canonical storage/binding token shared by PQC providers and the immutable
/// Keychain store. Whitespace aliases, control characters and unbounded
/// attacker-controlled account names are rejected instead of normalized.
enum PQCIdentityToken {
    static let maximumUTF8Length = 256

    static func validated(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw == trimmed,
              !raw.isEmpty,
              raw.utf8.count <= maximumUTF8Length,
              raw.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw PQCIdentityTokenError.invalid
        }
        return raw
    }
}

enum PQCKeyPairStoreBackend: String, Sendable {
    case appleCryptoKit = "apple-cryptokit"
    case liboqs = "liboqs"
}

enum PQCKeyPairStorePurpose: String, Sendable {
    case signature
    case kem
}

struct PQCKeyPairStoreStorageScope: Sendable {
    static let skyBridgeSharedIdentity = PQCKeyPairStoreStorageScope(
        canonicalLocation: nil,
        keychainScopeSource: .requiredEntitlement,
        includeLegacyKeychain: true
    )

    let canonicalLocation: KeychainGenericPasswordLocation?
    let keychainScopeSource: SkyBridgeSharedIdentityScopeSource
    let includeLegacyKeychain: Bool

    init(
        canonicalLocation: KeychainGenericPasswordLocation?,
        keychainScopeSource: SkyBridgeSharedIdentityScopeSource,
        includeLegacyKeychain: Bool
    ) {
        self.canonicalLocation = canonicalLocation
        self.keychainScopeSource = keychainScopeSource
        self.includeLegacyKeychain = includeLegacyKeychain
    }

    init(
        canonicalLocation: KeychainGenericPasswordLocation?,
        keychainScope: KeychainGenericPasswordScope,
        includeLegacyKeychain: Bool
    ) {
        self.init(
            canonicalLocation: canonicalLocation,
            keychainScopeSource: .explicitForTesting(keychainScope),
            includeLegacyKeychain: includeLegacyKeychain
        )
    }
}

struct PQCKeyPairStoreLegacyKeyPair: Sendable {
    let publicKeyLocation: KeychainGenericPasswordLocation
    let privateKeyLocation: KeychainGenericPasswordLocation
    let keychainScopeSource: SkyBridgeSharedIdentityScopeSource
    let includeLegacyKeychain: Bool

    init(
        publicKeyLocation: KeychainGenericPasswordLocation,
        privateKeyLocation: KeychainGenericPasswordLocation,
        keychainScopeSource: SkyBridgeSharedIdentityScopeSource,
        includeLegacyKeychain: Bool
    ) {
        self.publicKeyLocation = publicKeyLocation
        self.privateKeyLocation = privateKeyLocation
        self.keychainScopeSource = keychainScopeSource
        self.includeLegacyKeychain = includeLegacyKeychain
    }
}

/// Explicit legacy locations that may contain a private representation from
/// which the complete immutable key pair can be derived. A classifier must
/// distinguish a valid private key from a value owned by another role; the
/// store never treats an unparseable value as an absent migration candidate.
struct PQCKeyPairStoreDerivedPrivateLegacySources: Sendable {
    let privateKeyLocations: [KeychainGenericPasswordLocation]
    let keychainScopeSource: SkyBridgeSharedIdentityScopeSource
    let includeLegacyKeychain: Bool

    init(
        privateKeyLocations: [KeychainGenericPasswordLocation],
        keychainScopeSource: SkyBridgeSharedIdentityScopeSource,
        includeLegacyKeychain: Bool
    ) {
        self.privateKeyLocations = privateKeyLocations
        self.keychainScopeSource = keychainScopeSource
        self.includeLegacyKeychain = includeLegacyKeychain
    }
}

enum PQCKeyPairStoreDerivedPrivateLegacyCandidate {
    case keyPair(PQCKeyPairRecord)
    case differentRole
}

struct PQCKeyPairStoreDescriptor: Sendable {
    let backend: PQCKeyPairStoreBackend
    let purpose: PQCKeyPairStorePurpose
    let algorithm: String
    let identity: String
    let authority: PQCKeyPairStoreAuthority
    let authorityDomain: PQCBackendAuthorityDomain
    let storageScope: PQCKeyPairStoreStorageScope
    private let explicitAlgorithmIdentifier: String?

    init(
        backend: PQCKeyPairStoreBackend,
        purpose: PQCKeyPairStorePurpose,
        algorithm: String,
        identity: String,
        authority: PQCKeyPairStoreAuthority = .active,
        authorityDomain: PQCBackendAuthorityDomain = .quantumAdapter,
        storageScope: PQCKeyPairStoreStorageScope = .skyBridgeSharedIdentity,
        recordAlgorithmIdentifier: String? = nil
    ) {
        self.backend = backend
        self.purpose = purpose
        self.algorithm = algorithm
        self.identity = identity
        self.authority = authority
        self.authorityDomain = authorityDomain
        self.storageScope = storageScope
        self.explicitAlgorithmIdentifier = recordAlgorithmIdentifier
    }

    var algorithmIdentifier: String {
        explicitAlgorithmIdentifier
            ?? "\(backend.rawValue)/\(purpose.rawValue)/\(algorithm)"
    }
}

enum PQCKeyPairStoreError: Error, LocalizedError, Sendable {
    case invalidIdentity
    case invalidStorageLocation
    case stagedStorageRequiresManagedNamespace
    case conflictingLegacyStorageConfiguration
    case incompleteLegacyStorageConfiguration
    case incompleteLegacyKeyPair(algorithm: String)
    case conflictingLegacyKeyPair(algorithm: String)
    case canonicalRecordMissingDuringInspection
    case canonicalRecordMissingAfterInsert(algorithm: String)
    case conflictingBackendIdentity(
        algorithm: String,
        existing: PQCKeyPairStoreBackend,
        requested: PQCKeyPairStoreBackend
    )

    var errorDescription: String? {
        switch self {
        case .invalidIdentity:
            return "PQC key-pair identity is invalid"
        case .invalidStorageLocation:
            return "PQC key-pair storage location is invalid"
        case .stagedStorageRequiresManagedNamespace:
            return "Staged PQC key material must use its managed namespace until explicit promotion"
        case .conflictingLegacyStorageConfiguration:
            return "PQC legacy key-pair storage was configured more than once"
        case .incompleteLegacyStorageConfiguration:
            return "PQC legacy key-pair storage requires both public and private locations"
        case .incompleteLegacyKeyPair(let algorithm):
            return "Legacy \(algorithm) key-pair state is incomplete"
        case .conflictingLegacyKeyPair(let algorithm):
            return "Legacy \(algorithm) key-pair identity conflicts with the immutable canonical winner"
        case .canonicalRecordMissingDuringInspection:
            return "A canonical PQC key-pair record disappeared during strict metadata inspection"
        case .canonicalRecordMissingAfterInsert(let algorithm):
            return "Canonical \(algorithm) key-pair record is missing after atomic insertion"
        case let .conflictingBackendIdentity(algorithm, existing, requested):
            return "A canonical \(algorithm) identity already exists for \(existing.rawValue); explicit migration is required before using \(requested.rawValue)"
        }
    }
}

/// A security-layer, create-only single-item store for immutable PQC identities.
///
/// The Keychain item is the compare-and-set boundary: concurrent creators may
/// generate different candidates, but only one `SecItemAdd` succeeds and every
/// caller reloads that winner. Rotation intentionally is not part of this API.
enum PQCKeyPairStore {
    private static let servicePrefix = "com.skybridge.compass.pqc-keypair.v3"
    private static let stagedServicePrefix = "com.skybridge.compass.pqc-keypair-staged.v1"

    private enum WinnerConflictPolicy: Equatable {
        case adoptWinner
        case requireExactCandidate
    }

    #if DEBUG || SKYBRIDGE_TESTING
    private typealias TestingHook = @Sendable () throws -> Void

    private nonisolated static let canonicalMissHooks = OSAllocatedUnfairLock(
        initialState: [KeychainGenericPasswordLocation: TestingHook]()
    )
    private nonisolated static let splitDeletionHooks = OSAllocatedUnfairLock(
        initialState: [KeychainGenericPasswordLocation: TestingHook]()
    )

    static func installCanonicalMissHookForTesting(
        descriptor: PQCKeyPairStoreDescriptor,
        hook: @escaping @Sendable () throws -> Void
    ) throws {
        let location = try canonicalLocation(for: descriptor)
        canonicalMissHooks.withLock { hooks in
            hooks[location] = hook
        }
    }

    static func installSplitDeletionHookForTesting(
        descriptor: PQCKeyPairStoreDescriptor,
        hook: @escaping @Sendable () throws -> Void
    ) throws {
        let location = try canonicalLocation(for: descriptor)
        splitDeletionHooks.withLock { hooks in
            hooks[location] = hook
        }
    }

    static func clearReconciliationHooksForTesting(
        descriptor: PQCKeyPairStoreDescriptor
    ) throws {
        let location = try canonicalLocation(for: descriptor)
        _ = canonicalMissHooks.withLock { hooks in
            hooks.removeValue(forKey: location)
        }
        _ = splitDeletionHooks.withLock { hooks in
            hooks.removeValue(forKey: location)
        }
    }

    private static func runCanonicalMissHookForTesting(
        location: KeychainGenericPasswordLocation
    ) throws {
        let hook = canonicalMissHooks.withLock { hooks in
            hooks.removeValue(forKey: location)
        }
        try hook?()
    }

    private static func runSplitDeletionHookForTesting(
        location: KeychainGenericPasswordLocation
    ) throws {
        let hook = splitDeletionHooks.withLock { hooks in
            hooks.removeValue(forKey: location)
        }
        try hook?()
    }
    #endif

    static func load(
        descriptor: PQCKeyPairStoreDescriptor,
        publicKeyLength: Int,
        privateKeyLength: Int,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord? {
        try validateDescriptor(descriptor)
        let keychainScope = try descriptor.storageScope.keychainScopeSource.resolve()
        return try load(
            descriptor: descriptor,
            keychainScope: keychainScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            validatePair: validatePair
        )
    }

    private static func load(
        descriptor: PQCKeyPairStoreDescriptor,
        keychainScope: KeychainGenericPasswordScope,
        publicKeyLength: Int,
        privateKeyLength: Int,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord? {
        let location = try canonicalLocation(for: descriptor)
        let authoritativeScope = try keychainScope.authoritativeOnly()
        if let record = try loadAuthoritativeRecord(
            descriptor: descriptor,
            keychainScope: keychainScope,
            location: location,
            authoritativeScope: authoritativeScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            validatePair: validatePair
        ) {
            return record
        }

        #if DEBUG || SKYBRIDGE_TESTING
        try runCanonicalMissHookForTesting(location: location)
        #endif
        var candidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: location.service,
                account: location.account,
                includeLegacyKeychain: descriptor.storageScope
                    .includeLegacyKeychain
            )
        defer {
            for index in candidates.indices {
                PQCKeyPairRecordCodec.wipe(&candidates[index].data)
            }
        }
        let legacyCandidateIndices = candidates.indices.filter { index in
            !isAuthoritative(
                candidates[index].location,
                authoritativeScope: authoritativeScope
            )
        }
        guard !candidates.isEmpty else { return nil }
        guard let firstIndex = legacyCandidateIndices.first else {
            // A concurrent creator may have inserted the authoritative winner
            // after the strict read missed. Reload it through the strict path;
            // the broad snapshot is discovery-only and never a delete plan.
            guard let winner = try loadAuthoritativeRecord(
                descriptor: descriptor,
                keychainScope: keychainScope,
                location: location,
                authoritativeScope: authoritativeScope,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                validatePair: validatePair
            ) else {
                throw PQCKeyPairStoreError.canonicalRecordMissingDuringInspection
            }
            return winner
        }
        var firstRecord = try decodeAndValidateLegacyCandidate(
            candidates[firstIndex].data,
            descriptor: descriptor,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            validatePair: validatePair
        )
        defer { PQCKeyPairRecordCodec.wipe(&firstRecord.privateKey) }
        for index in legacyCandidateIndices.dropFirst() {
            var record = try decodeAndValidateLegacyCandidate(
                candidates[index].data,
                descriptor: descriptor,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                validatePair: validatePair
            )
            defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }
            guard record == firstRecord else {
                throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
        }
        let winner = try insertAndReloadWinner(
            firstRecord,
            descriptor: descriptor,
            keychainScope: keychainScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            conflictPolicy: .requireExactCandidate,
            validatePair: validatePair
        )
        // `insertAndReloadWinner` performs a fresh strict load followed by a
        // fresh legacy reconciliation. Never delete from this pre-CAS snapshot.
        return winner
    }

    private static func loadAuthoritativeRecord(
        descriptor: PQCKeyPairStoreDescriptor,
        keychainScope: KeychainGenericPasswordScope,
        location: KeychainGenericPasswordLocation,
        authoritativeScope: KeychainGenericPasswordScope,
        publicKeyLength: Int,
        privateKeyLength: Int,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord? {
        guard var authoritativeEncoded = try KeychainManager.shared.exportKeyStrict(
            service: location.service,
            account: location.account,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) else {
            return nil
        }
        defer { PQCKeyPairRecordCodec.wipe(&authoritativeEncoded) }
        var record = try decodeAndValidate(
            authoritativeEncoded,
            descriptor: descriptor,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            validatePair: validatePair
        )
        do {
            try requireAuthority(
                for: descriptor,
                keychainScope: keychainScope
            )
            try reconcileCanonicalLegacyCandidates(
                with: record,
                descriptor: descriptor,
                location: location,
                authoritativeScope: authoritativeScope,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                validatePair: validatePair
            )
            return record
        } catch {
            PQCKeyPairRecordCodec.wipe(&record.privateKey)
            throw error
        }
    }

    static func loadOrCreate(
        descriptor: PQCKeyPairStoreDescriptor,
        publicKeyLength: Int,
        privateKeyLength: Int,
        legacyPublicService: String? = nil,
        legacyPrivateService: String? = nil,
        legacyKeyPair: PQCKeyPairStoreLegacyKeyPair? = nil,
        validatePair: (PQCKeyPairRecord) throws -> Void,
        generate: () throws -> PQCKeyPairRecord
    ) throws -> PQCKeyPairRecord {
        try validateDescriptor(descriptor)
        let keychainScope = try descriptor.storageScope.keychainScopeSource.resolve()
        if let migrated = try loadOrMigrateLegacy(
            descriptor: descriptor,
            keychainScope: keychainScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            legacyPublicService: legacyPublicService,
            legacyPrivateService: legacyPrivateService,
            legacyKeyPair: legacyKeyPair,
            validatePair: validatePair
        ) {
            return migrated
        }

        var candidate = try generate()
        defer { PQCKeyPairRecordCodec.wipe(&candidate.privateKey) }
        try validatePair(candidate)
        return try insertAndReloadWinner(
            candidate,
            descriptor: descriptor,
            keychainScope: keychainScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            conflictPolicy: .adoptWinner,
            validatePair: validatePair
        )
    }

    static func loadOrMigrateLegacy(
        descriptor: PQCKeyPairStoreDescriptor,
        publicKeyLength: Int,
        privateKeyLength: Int,
        legacyPublicService: String? = nil,
        legacyPrivateService: String? = nil,
        legacyKeyPair: PQCKeyPairStoreLegacyKeyPair? = nil,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord? {
        try validateDescriptor(descriptor)
        let keychainScope = try descriptor.storageScope.keychainScopeSource.resolve()
        return try loadOrMigrateLegacy(
            descriptor: descriptor,
            keychainScope: keychainScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            legacyPublicService: legacyPublicService,
            legacyPrivateService: legacyPrivateService,
            legacyKeyPair: legacyKeyPair,
            validatePair: validatePair
        )
    }

    private static func loadOrMigrateLegacy(
        descriptor: PQCKeyPairStoreDescriptor,
        keychainScope: KeychainGenericPasswordScope,
        publicKeyLength: Int,
        privateKeyLength: Int,
        legacyPublicService: String?,
        legacyPrivateService: String?,
        legacyKeyPair: PQCKeyPairStoreLegacyKeyPair?,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord? {
        var existing = try load(
            descriptor: descriptor,
            keychainScope: keychainScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            validatePair: validatePair
        )
        do {
            guard let legacyStorage = try resolvedLegacyKeyPair(
                descriptor: descriptor,
                legacyPublicService: legacyPublicService,
                legacyPrivateService: legacyPrivateService,
                legacyKeyPair: legacyKeyPair
            ) else {
                return existing
            }
            _ = try legacyStorage.keychainScopeSource.resolve().authoritativeOnly()

            if existing != nil {
                var canonicalRecord = existing!
                existing = nil
                do {
                    try reconcileSplitLegacyCandidates(
                        with: canonicalRecord,
                        descriptor: descriptor,
                        legacyStorage: legacyStorage
                    )
                    return canonicalRecord
                } catch {
                    PQCKeyPairRecordCodec.wipe(&canonicalRecord.privateKey)
                    throw error
                }
            }

            return try migrateCompleteLegacyPair(
                descriptor: descriptor,
                keychainScope: keychainScope,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                legacyStorage: legacyStorage,
                validatePair: validatePair
            )
        } catch {
            wipeOwnedRecord(&existing)
            throw error
        }
    }

    /// Loads the canonical pair or migrates one or more private-only legacy
    /// representations. Every candidate that belongs to this role must derive
    /// the same complete pair across all visible Keychain namespaces. Values
    /// explicitly classified as another role are retained for that role's own
    /// reconciliation; malformed candidates must be thrown by `classify`.
    static func loadOrMigrateDerivedPrivateLegacy(
        descriptor: PQCKeyPairStoreDescriptor,
        publicKeyLength: Int,
        privateKeyLength: Int,
        legacySources: PQCKeyPairStoreDerivedPrivateLegacySources,
        classify: (
            _ service: String,
            _ privateRepresentation: Data
        ) throws -> PQCKeyPairStoreDerivedPrivateLegacyCandidate,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord? {
        try validateDescriptor(descriptor)
        let keychainScope = try descriptor.storageScope.keychainScopeSource.resolve()
        _ = try legacySources.keychainScopeSource.resolve().authoritativeOnly()
        try validateDerivedPrivateLegacySources(legacySources)

        var existing = try load(
            descriptor: descriptor,
            keychainScope: keychainScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            validatePair: validatePair
        )
        do {
            if existing != nil {
                var canonicalRecord = existing!
                existing = nil
                do {
                    try reconcileDerivedPrivateLegacyCandidates(
                        with: canonicalRecord,
                        descriptor: descriptor,
                        legacySources: legacySources,
                        publicKeyLength: publicKeyLength,
                        privateKeyLength: privateKeyLength,
                        classify: classify,
                        validatePair: validatePair
                    )
                    return canonicalRecord
                } catch {
                    PQCKeyPairRecordCodec.wipe(&canonicalRecord.privateKey)
                    throw error
                }
            }

            var selectedRecord = try derivedPrivateLegacyRecord(
                descriptor: descriptor,
                legacySources: legacySources,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                classify: classify,
                validatePair: validatePair
            )
            defer { wipeOwnedRecord(&selectedRecord) }
            guard selectedRecord != nil else { return nil }
            var candidateRecord = selectedRecord!
            selectedRecord = nil
            defer { PQCKeyPairRecordCodec.wipe(&candidateRecord.privateKey) }

            var winner = try insertAndReloadWinner(
                candidateRecord,
                descriptor: descriptor,
                keychainScope: keychainScope,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                conflictPolicy: .requireExactCandidate,
                validatePair: validatePair
            )
            do {
                try reconcileDerivedPrivateLegacyCandidates(
                    with: winner,
                    descriptor: descriptor,
                    legacySources: legacySources,
                    publicKeyLength: publicKeyLength,
                    privateKeyLength: privateKeyLength,
                    classify: classify,
                    validatePair: validatePair
                )
                return winner
            } catch {
                PQCKeyPairRecordCodec.wipe(&winner.privateKey)
                throw error
            }
        } catch {
            wipeOwnedRecord(&existing)
            throw error
        }
    }

    private static func derivedPrivateLegacyRecord(
        descriptor: PQCKeyPairStoreDescriptor,
        legacySources: PQCKeyPairStoreDerivedPrivateLegacySources,
        publicKeyLength: Int,
        privateKeyLength: Int,
        classify: (
            _ service: String,
            _ privateRepresentation: Data
        ) throws -> PQCKeyPairStoreDerivedPrivateLegacyCandidate,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord? {
        var candidates = try derivedPrivateLegacyCandidates(
            legacySources: legacySources
        )
        defer { wipeLegacyCandidates(&candidates) }

        var selectedRecord: PQCKeyPairRecord?
        defer { wipeOwnedRecord(&selectedRecord) }
        for index in candidates.indices {
            switch try classifyDerivedPrivateLegacyCandidate(
                candidates[index],
                descriptor: descriptor,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                classify: classify,
                validatePair: validatePair
            ) {
            case .differentRole:
                continue
            case .keyPair(var record):
                if let selectedRecord {
                    guard selectedRecord == record else {
                        PQCKeyPairRecordCodec.wipe(&record.privateKey)
                        throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                            algorithm: descriptor.algorithm
                        )
                    }
                    PQCKeyPairRecordCodec.wipe(&record.privateKey)
                } else {
                    selectedRecord = record
                }
            }
        }
        guard selectedRecord != nil else { return nil }
        let record = selectedRecord!
        selectedRecord = nil
        return record
    }

    private static func reconcileDerivedPrivateLegacyCandidates(
        with canonicalRecord: PQCKeyPairRecord,
        descriptor: PQCKeyPairStoreDescriptor,
        legacySources: PQCKeyPairStoreDerivedPrivateLegacySources,
        publicKeyLength: Int,
        privateKeyLength: Int,
        classify: (
            _ service: String,
            _ privateRepresentation: Data
        ) throws -> PQCKeyPairStoreDerivedPrivateLegacyCandidate,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws {
        var candidates = try derivedPrivateLegacyCandidates(
            legacySources: legacySources
        )
        defer { wipeLegacyCandidates(&candidates) }
        var matchingIndices: [Int] = []
        matchingIndices.reserveCapacity(candidates.count)

        // Complete classification and validation before deleting any item. A
        // conflicting or malformed candidate therefore remains durable across
        // retries instead of being partially hidden by cleanup.
        for index in candidates.indices {
            switch try classifyDerivedPrivateLegacyCandidate(
                candidates[index],
                descriptor: descriptor,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                classify: classify,
                validatePair: validatePair
            ) {
            case .differentRole:
                continue
            case .keyPair(var record):
                guard record == canonicalRecord else {
                    PQCKeyPairRecordCodec.wipe(&record.privateKey)
                    throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                        algorithm: descriptor.algorithm
                    )
                }
                PQCKeyPairRecordCodec.wipe(&record.privateKey)
                matchingIndices.append(index)
            }
        }

        let canonicalLocation = try canonicalLocation(for: descriptor)
        for index in matchingIndices {
            try KeychainManager.shared.deleteLegacyGenericPasswordCandidate(
                candidates[index]
            )
            #if DEBUG || SKYBRIDGE_TESTING
            try runSplitDeletionHookForTesting(location: canonicalLocation)
            #endif
        }
    }

    private static func classifyDerivedPrivateLegacyCandidate(
        _ candidate: LegacyGenericPasswordCandidate,
        descriptor: PQCKeyPairStoreDescriptor,
        publicKeyLength: Int,
        privateKeyLength: Int,
        classify: (
            _ service: String,
            _ privateRepresentation: Data
        ) throws -> PQCKeyPairStoreDerivedPrivateLegacyCandidate,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairStoreDerivedPrivateLegacyCandidate {
        do {
            switch try classify(candidate.service, candidate.data) {
            case .differentRole:
                return .differentRole
            case .keyPair(var record):
                guard record.algorithmIdentifier == descriptor.algorithmIdentifier,
                      record.publicKey.count == publicKeyLength,
                      record.privateKey.count == privateKeyLength else {
                    PQCKeyPairRecordCodec.wipe(&record.privateKey)
                    throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                        algorithm: descriptor.algorithm
                    )
                }
                do {
                    try validatePair(record)
                    return .keyPair(record)
                } catch {
                    PQCKeyPairRecordCodec.wipe(&record.privateKey)
                    throw error
                }
            }
        } catch let error as PQCKeyPairStoreError {
            throw error
        } catch {
            throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                algorithm: descriptor.algorithm
            )
        }
    }

    private static func derivedPrivateLegacyCandidates(
        legacySources: PQCKeyPairStoreDerivedPrivateLegacySources
    ) throws -> [LegacyGenericPasswordCandidate] {
        var candidates: [LegacyGenericPasswordCandidate] = []
        do {
            for location in legacySources.privateKeyLocations {
                let discovered = try KeychainManager.shared
                    .legacyGenericPasswordCandidatesStrict(
                        service: location.service,
                        account: location.account,
                        includeLegacyKeychain: legacySources.includeLegacyKeychain
                    )
                candidates.append(contentsOf: discovered)
            }
            return candidates
        } catch {
            wipeLegacyCandidates(&candidates)
            throw error
        }
    }

    private static func validateDerivedPrivateLegacySources(
        _ legacySources: PQCKeyPairStoreDerivedPrivateLegacySources
    ) throws {
        guard !legacySources.privateKeyLocations.isEmpty else {
            throw PQCKeyPairStoreError.incompleteLegacyStorageConfiguration
        }
        for location in legacySources.privateKeyLocations {
            try validate(location: location)
        }
        guard Set(legacySources.privateKeyLocations).count
                == legacySources.privateKeyLocations.count else {
            throw PQCKeyPairStoreError.conflictingLegacyStorageConfiguration
        }
    }

    private static func migrateCompleteLegacyPair(
        descriptor: PQCKeyPairStoreDescriptor,
        keychainScope: KeychainGenericPasswordScope,
        publicKeyLength: Int,
        privateKeyLength: Int,
        legacyStorage: PQCKeyPairStoreLegacyKeyPair,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord? {
        var publicCandidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: legacyStorage.publicKeyLocation.service,
                account: legacyStorage.publicKeyLocation.account,
                includeLegacyKeychain: legacyStorage.includeLegacyKeychain
            )
        defer { wipeLegacyCandidates(&publicCandidates) }
        var privateCandidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: legacyStorage.privateKeyLocation.service,
                account: legacyStorage.privateKeyLocation.account,
                includeLegacyKeychain: legacyStorage.includeLegacyKeychain
            )
        defer { wipeLegacyCandidates(&privateCandidates) }
        guard !publicCandidates.isEmpty || !privateCandidates.isEmpty else {
            return nil
        }

        var publicByNamespace: [LegacyNamespace: Int] = [:]
        for index in publicCandidates.indices {
            let namespace = LegacyNamespace(publicCandidates[index].location)
            guard publicByNamespace.updateValue(index, forKey: namespace) == nil else {
                throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
        }
        var privateByNamespace: [LegacyNamespace: Int] = [:]
        for index in privateCandidates.indices {
            let namespace = LegacyNamespace(privateCandidates[index].location)
            guard privateByNamespace.updateValue(index, forKey: namespace) == nil else {
                throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
        }
        guard Set(publicByNamespace.keys) == Set(privateByNamespace.keys) else {
            throw PQCKeyPairStoreError.incompleteLegacyKeyPair(
                algorithm: descriptor.algorithm
            )
        }

        var selectedLegacyRecord: PQCKeyPairRecord?
        defer { wipeOwnedRecord(&selectedLegacyRecord) }
        for namespace in publicByNamespace.keys {
            guard let publicIndex = publicByNamespace[namespace],
                  let privateIndex = privateByNamespace[namespace] else {
                throw PQCKeyPairStoreError.incompleteLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
            var legacyRecord = PQCKeyPairRecord(
                algorithmIdentifier: descriptor.algorithmIdentifier,
                publicKey: publicCandidates[publicIndex].data,
                privateKey: privateCandidates[privateIndex].data
            )
            do {
                try validatePair(legacyRecord)
            } catch {
                PQCKeyPairRecordCodec.wipe(&legacyRecord.privateKey)
                throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
            if let selectedRecord = selectedLegacyRecord {
                guard selectedRecord == legacyRecord else {
                    PQCKeyPairRecordCodec.wipe(&legacyRecord.privateKey)
                    throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                        algorithm: descriptor.algorithm
                    )
                }
                PQCKeyPairRecordCodec.wipe(&legacyRecord.privateKey)
            } else {
                selectedLegacyRecord = legacyRecord
            }
        }
        guard selectedLegacyRecord != nil else { return nil }
        var candidateRecord = selectedLegacyRecord!
        selectedLegacyRecord = nil
        defer { PQCKeyPairRecordCodec.wipe(&candidateRecord.privateKey) }

        var winner = try insertAndReloadWinner(
            candidateRecord,
            descriptor: descriptor,
            keychainScope: keychainScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            conflictPolicy: .requireExactCandidate,
            validatePair: validatePair
        )
        do {
            // Re-scan after CAS. Persistent references from the pre-CAS
            // snapshot are never used as a post-CAS delete plan.
            try reconcileSplitLegacyCandidates(
                with: winner,
                descriptor: descriptor,
                legacyStorage: legacyStorage
            )
            return winner
        } catch {
            PQCKeyPairRecordCodec.wipe(&winner.privateKey)
            throw error
        }
    }

    private struct LegacyNamespace: Hashable {
        let actualAccessGroup: String?
        let usesDataProtectionKeychain: Bool

        init(_ location: LegacySecItemLocation) {
            actualAccessGroup = location.actualAccessGroup
            usesDataProtectionKeychain = location.usesDataProtectionKeychain
        }
    }

    private static func reconcileSplitLegacyCandidates(
        with canonicalRecord: PQCKeyPairRecord,
        descriptor: PQCKeyPairStoreDescriptor,
        legacyStorage: PQCKeyPairStoreLegacyKeyPair
    ) throws {
        var publicCandidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: legacyStorage.publicKeyLocation.service,
                account: legacyStorage.publicKeyLocation.account,
                includeLegacyKeychain: legacyStorage.includeLegacyKeychain
            )
        defer { wipeLegacyCandidates(&publicCandidates) }
        var privateCandidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: legacyStorage.privateKeyLocation.service,
                account: legacyStorage.privateKeyLocation.account,
                includeLegacyKeychain: legacyStorage.includeLegacyKeychain
            )
        defer { wipeLegacyCandidates(&privateCandidates) }

        // Validate every remnant before mutating any item. A conflicting half
        // pair remains durable and visible on every retry.
        for index in publicCandidates.indices {
            guard publicCandidates[index].data == canonicalRecord.publicKey else {
                throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
        }
        for index in privateCandidates.indices {
            guard privateCandidates[index].data == canonicalRecord.privateKey else {
                throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
        }

        let location = try canonicalLocation(for: descriptor)
        for index in publicCandidates.indices {
            try KeychainManager.shared
                .deleteLegacyGenericPasswordCandidate(publicCandidates[index])
            #if DEBUG || SKYBRIDGE_TESTING
            try runSplitDeletionHookForTesting(location: location)
            #endif
        }
        for index in privateCandidates.indices {
            try KeychainManager.shared
                .deleteLegacyGenericPasswordCandidate(privateCandidates[index])
            #if DEBUG || SKYBRIDGE_TESTING
            try runSplitDeletionHookForTesting(location: location)
            #endif
        }
    }

    private static func wipeLegacyCandidates(
        _ candidates: inout [LegacyGenericPasswordCandidate]
    ) {
        for index in candidates.indices {
            PQCKeyPairRecordCodec.wipe(&candidates[index].data)
        }
    }

    private static func wipeOwnedRecord(
        _ record: inout PQCKeyPairRecord?
    ) {
        guard var ownedRecord = record else { return }
        record = nil
        PQCKeyPairRecordCodec.wipe(&ownedRecord.privateKey)
    }

    static func insertIfAbsent(
        _ candidate: PQCKeyPairRecord,
        descriptor: PQCKeyPairStoreDescriptor,
        publicKeyLength: Int,
        privateKeyLength: Int,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord {
        try validateDescriptor(descriptor)
        let keychainScope = try descriptor.storageScope.keychainScopeSource.resolve()
        try validatePair(candidate)
        return try insertAndReloadWinner(
            candidate,
            descriptor: descriptor,
            keychainScope: keychainScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            conflictPolicy: .adoptWinner,
            validatePair: validatePair
        )
    }

    static func deleteForTesting(descriptor: PQCKeyPairStoreDescriptor) throws {
        let location = try canonicalLocation(for: descriptor)
        let keychainScope = try descriptor.storageScope.keychainScopeSource.resolve()
        try KeychainManager.shared.deleteAPIKey(
            service: location.service,
            account: location.account,
            scope: keychainScope,
            includeLegacyKeychain: descriptor.storageScope.includeLegacyKeychain
        )
    }

    #if DEBUG || SKYBRIDGE_TESTING
    @discardableResult
    static func insertUnscopedCanonicalRecordForTesting(
        _ candidate: PQCKeyPairRecord,
        descriptor: PQCKeyPairStoreDescriptor
    ) throws -> KeychainInsertResult {
        guard descriptor.authority == .active else {
            throw PQCKeyPairStoreError.stagedStorageRequiresManagedNamespace
        }
        let location = try canonicalLocation(for: descriptor)
        var encoded = try PQCKeyPairRecordCodec.encode(candidate)
        defer { PQCKeyPairRecordCodec.wipe(&encoded) }
        return try KeychainManager.shared.insertKeyIfAbsent(
            data: encoded,
            service: location.service,
            account: location.account,
            scope: .unscopedDataProtectionForTesting
        )
    }

    static func deleteUnscopedCanonicalRecordForTesting(
        descriptor: PQCKeyPairStoreDescriptor
    ) throws {
        let location = try canonicalLocation(for: descriptor)
        try KeychainManager.shared.deleteAPIKey(
            service: location.service,
            account: location.account,
            scope: .unscopedDataProtectionForTesting,
            includeLegacyKeychain: false
        )
    }
    #endif

    static func canonicalService(
        backend: PQCKeyPairStoreBackend,
        purpose: PQCKeyPairStorePurpose
    ) -> String {
        "\(servicePrefix).\(backend.rawValue).\(purpose.rawValue)"
    }

    /// Strictly inspects every authoritative record in a backend/purpose
    /// service without returning key bytes. Any corrupt or concurrently missing
    /// record aborts classification instead of becoming ambiguous evidence.
    static func canonicalRecordMetadata(
        backend: PQCKeyPairStoreBackend,
        purpose: PQCKeyPairStorePurpose,
        keychainScope: KeychainGenericPasswordScope
    ) throws -> [PQCKeyPairRecordMetadata] {
        let service = canonicalService(backend: backend, purpose: purpose)
        let authoritativeScope = try keychainScope.authoritativeOnly()
        let accounts = try KeychainManager.shared.genericPasswordAccountsStrict(
            service: service,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        )
        return try accounts.sorted().map { account in
            guard var encoded = try KeychainManager.shared.exportKeyStrict(
                service: service,
                account: account,
                scope: authoritativeScope,
                includeLegacyKeychain: false
            ) else {
                throw PQCKeyPairStoreError.canonicalRecordMissingDuringInspection
            }
            defer { PQCKeyPairRecordCodec.wipe(&encoded) }
            return try PQCKeyPairRecordCodec.inspectMetadata(encoded)
        }
    }

    private static func decodeAndValidate(
        _ encoded: Data,
        descriptor: PQCKeyPairStoreDescriptor,
        publicKeyLength: Int,
        privateKeyLength: Int,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord {
        var record = try PQCKeyPairRecordCodec.decode(
            encoded,
            expectedAlgorithmIdentifier: descriptor.algorithmIdentifier,
            expectedPublicKeyLength: publicKeyLength,
            expectedPrivateKeyLength: privateKeyLength
        )
        do {
            try validatePair(record)
            return record
        } catch {
            PQCKeyPairRecordCodec.wipe(&record.privateKey)
            throw error
        }
    }

    private static func decodeAndValidateLegacyCandidate(
        _ encoded: Data,
        descriptor: PQCKeyPairStoreDescriptor,
        publicKeyLength: Int,
        privateKeyLength: Int,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord {
        do {
            return try decodeAndValidate(
                encoded,
                descriptor: descriptor,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                validatePair: validatePair
            )
        } catch {
            throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                algorithm: descriptor.algorithm
            )
        }
    }

    private static func reconcileCanonicalLegacyCandidates(
        with canonicalRecord: PQCKeyPairRecord,
        descriptor: PQCKeyPairStoreDescriptor,
        location: KeychainGenericPasswordLocation,
        authoritativeScope: KeychainGenericPasswordScope,
        publicKeyLength: Int,
        privateKeyLength: Int,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws {
        var candidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
            service: location.service,
            account: location.account,
            includeLegacyKeychain: descriptor.storageScope
                .includeLegacyKeychain
        )
        defer {
            for index in candidates.indices {
                PQCKeyPairRecordCodec.wipe(&candidates[index].data)
            }
        }
        for index in candidates.indices {
            guard !isAuthoritative(
                candidates[index].location,
                authoritativeScope: authoritativeScope
            ) else {
                continue
            }
            var record = try decodeAndValidateLegacyCandidate(
                candidates[index].data,
                descriptor: descriptor,
                publicKeyLength: publicKeyLength,
                privateKeyLength: privateKeyLength,
                validatePair: validatePair
            )
            defer { PQCKeyPairRecordCodec.wipe(&record.privateKey) }
            guard record == canonicalRecord else {
                throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                    algorithm: descriptor.algorithm
                )
            }
            try KeychainManager.shared
                .deleteLegacyGenericPasswordCandidate(candidates[index])
        }
    }

    private static func isAuthoritative(
        _ location: LegacySecItemLocation,
        authoritativeScope: KeychainGenericPasswordScope
    ) -> Bool {
        guard let authoritativeAccessGroup = authoritativeScope.writeAccessGroup else {
            return false
        }
        return location.actualAccessGroup == authoritativeAccessGroup
            && location.usesDataProtectionKeychain
                == authoritativeScope.usesDataProtectionKeychain
    }

    private static func insertAndReloadWinner(
        _ candidate: PQCKeyPairRecord,
        descriptor: PQCKeyPairStoreDescriptor,
        keychainScope: KeychainGenericPasswordScope,
        publicKeyLength: Int,
        privateKeyLength: Int,
        conflictPolicy: WinnerConflictPolicy,
        validatePair: (PQCKeyPairRecord) throws -> Void
    ) throws -> PQCKeyPairRecord {
        try requireAuthority(for: descriptor, keychainScope: keychainScope)
        let location = try canonicalLocation(for: descriptor)
        var encoded = try PQCKeyPairRecordCodec.encode(candidate)
        defer { PQCKeyPairRecordCodec.wipe(&encoded) }
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: encoded,
            service: location.service,
            account: location.account,
            scope: keychainScope
        )
        guard var winner = try load(
            descriptor: descriptor,
            keychainScope: keychainScope,
            publicKeyLength: publicKeyLength,
            privateKeyLength: privateKeyLength,
            validatePair: validatePair
        ) else {
            throw PQCKeyPairStoreError.canonicalRecordMissingAfterInsert(
                algorithm: descriptor.algorithm
            )
        }
        if conflictPolicy == .requireExactCandidate,
           winner != candidate {
            PQCKeyPairRecordCodec.wipe(&winner.privateKey)
            throw PQCKeyPairStoreError.conflictingLegacyKeyPair(
                algorithm: descriptor.algorithm
            )
        }
        return winner
    }

    private static func canonicalLocation(
        for descriptor: PQCKeyPairStoreDescriptor
    ) throws -> KeychainGenericPasswordLocation {
        let identity = try normalizedIdentity(descriptor.identity)
        if let explicitLocation = descriptor.storageScope.canonicalLocation {
            guard descriptor.authority == .active else {
                throw PQCKeyPairStoreError.stagedStorageRequiresManagedNamespace
            }
            try validate(location: explicitLocation)
            return explicitLocation
        }
        let identityHash = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let algorithmHash = SHA256.hash(data: Data(descriptor.algorithmIdentifier.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return KeychainGenericPasswordLocation(
            service: managedService(for: descriptor),
            account: "\(algorithmHash).\(identityHash)"
        )
    }

    private static func managedService(
        for descriptor: PQCKeyPairStoreDescriptor
    ) -> String {
        switch descriptor.authority {
        case .active:
            return canonicalService(
                backend: descriptor.backend,
                purpose: descriptor.purpose
            )
        case .staged:
            return "\(stagedServicePrefix).\(descriptor.backend.rawValue).\(descriptor.purpose.rawValue)"
        }
    }

    private static func resolvedLegacyKeyPair(
        descriptor: PQCKeyPairStoreDescriptor,
        legacyPublicService: String?,
        legacyPrivateService: String?,
        legacyKeyPair: PQCKeyPairStoreLegacyKeyPair?
    ) throws -> PQCKeyPairStoreLegacyKeyPair? {
        if legacyKeyPair != nil,
           legacyPublicService != nil || legacyPrivateService != nil {
            throw PQCKeyPairStoreError.conflictingLegacyStorageConfiguration
        }
        if let legacyKeyPair {
            try validate(location: legacyKeyPair.publicKeyLocation)
            try validate(location: legacyKeyPair.privateKeyLocation)
            return legacyKeyPair
        }

        switch (legacyPublicService, legacyPrivateService) {
        case (nil, nil):
            return nil
        case let (publicService?, privateService?):
            let account = try normalizedIdentity(descriptor.identity)
            let legacyStorage = PQCKeyPairStoreLegacyKeyPair(
                publicKeyLocation: KeychainGenericPasswordLocation(
                    service: publicService,
                    account: account
                ),
                privateKeyLocation: KeychainGenericPasswordLocation(
                    service: privateService,
                    account: account
                ),
                keychainScopeSource: descriptor.storageScope.keychainScopeSource,
                includeLegacyKeychain: descriptor.storageScope.includeLegacyKeychain
            )
            try validate(location: legacyStorage.publicKeyLocation)
            try validate(location: legacyStorage.privateKeyLocation)
            return legacyStorage
        case (.some, nil), (nil, .some):
            throw PQCKeyPairStoreError.incompleteLegacyStorageConfiguration
        }
    }

    private static func validate(
        location: KeychainGenericPasswordLocation
    ) throws {
        guard !location.service.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !location.account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PQCKeyPairStoreError.invalidStorageLocation
        }
    }

    private static func requireAuthority(
        for descriptor: PQCKeyPairStoreDescriptor,
        keychainScope: KeychainGenericPasswordScope
    ) throws {
        guard descriptor.authority == .active else { return }
        do {
            try PQCBackendAuthorityStore.claim(
                descriptor.backend,
                domain: descriptor.authorityDomain,
                keychainScope: keychainScope
            )
        } catch let error as PQCBackendAuthorityError {
            guard case let .conflictingBackend(existing, requested) = error else {
                throw error
            }
            throw PQCKeyPairStoreError.conflictingBackendIdentity(
                algorithm: descriptor.algorithm,
                existing: existing,
                requested: requested
            )
        }
    }

    private static func normalizedIdentity(_ raw: String) throws -> String {
        do {
            return try PQCIdentityToken.validated(raw)
        } catch {
            throw PQCKeyPairStoreError.invalidIdentity
        }
    }

    private static func validateDescriptor(
        _ descriptor: PQCKeyPairStoreDescriptor
    ) throws {
        _ = try normalizedIdentity(descriptor.identity)
    }
}
