import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The one immutable app/extension-shared authority for the conventional
/// P-256 device identity. The private key remains a Keychain key item; this
/// record binds its unique application tag to the exact public identity.
struct DeviceIdentityAuthorityRecord: Codable, Equatable, Sendable {
    static let currentVersion: UInt8 = 1
    static let privateKeyTagPrefix = "com.skybridge.p2p.identity.signing.v2."
    static let maximumEncodedSize = 4_096

    let version: UInt8
    let deviceId: String
    let publicKey: Data
    let publicKeyFingerprint: String
    let privateKeyApplicationTag: String
    let isSecureEnclave: Bool
    let createdAt: Date

    init(
        version: UInt8 = currentVersion,
        deviceId: String,
        publicKey: Data,
        publicKeyFingerprint: String,
        privateKeyApplicationTag: String,
        isSecureEnclave: Bool,
        createdAt: Date = Date()
    ) {
        self.version = version
        self.deviceId = deviceId
        self.publicKey = publicKey
        self.publicKeyFingerprint = publicKeyFingerprint
        self.privateKeyApplicationTag = privateKeyApplicationTag
        self.isSecureEnclave = isSecureEnclave
        self.createdAt = createdAt
    }

    static func uniquePrivateKeyApplicationTag() -> String {
        privateKeyTagPrefix + UUID().uuidString.lowercased()
    }

    func validated() throws -> DeviceIdentityAuthorityRecord {
        guard version == Self.currentVersion else {
            throw DeviceIdentityAuthorityError.unsupportedRecordVersion(version)
        }
        let normalizedDeviceId = deviceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedDeviceId == deviceId,
              !normalizedDeviceId.isEmpty,
              normalizedDeviceId.utf8.count <= 256,
              normalizedDeviceId.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DeviceIdentityAuthorityError.invalidDeviceId
        }
        guard privateKeyApplicationTag.hasPrefix(Self.privateKeyTagPrefix),
              privateKeyApplicationTag.utf8.count <= 160 else {
            throw DeviceIdentityAuthorityError.invalidPrivateKeyApplicationTag
        }
        let tagSuffix = String(
            privateKeyApplicationTag.dropFirst(Self.privateKeyTagPrefix.count)
        )
        guard let tagUUID = UUID(uuidString: tagSuffix),
              tagUUID.uuidString.lowercased() == tagSuffix else {
            throw DeviceIdentityAuthorityError.invalidPrivateKeyApplicationTag
        }
        do {
            _ = try P256.Signing.PublicKey(x963Representation: publicKey)
        } catch {
            throw DeviceIdentityAuthorityError.invalidPublicKey
        }
        let expectedFingerprint = Self.fingerprint(for: publicKey)
        guard publicKeyFingerprint == expectedFingerprint else {
            throw DeviceIdentityAuthorityError.publicKeyFingerprintMismatch
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DeviceIdentityAuthorityError.invalidCreatedAt
        }
        return self
    }

    static func fingerprint(for publicKey: Data) -> String {
        SHA256.hash(data: publicKey)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum DeviceIdentityAuthorityError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedRecordVersion(UInt8)
    case invalidDeviceId
    case invalidPublicKey
    case publicKeyFingerprintMismatch
    case invalidPrivateKeyApplicationTag
    case invalidCreatedAt
    case corruptAuthorityRecord
    case authorityWinnerMissing
    case authorityWinnerKeyMissing(String)
    case authorityWinnerPublicKeyMismatch
    case authorityWinnerSecureEnclaveMismatch
    case candidateKeyPublicKeyMismatch
    case candidateCleanupFailed(String)
    case legacyIdentityConflictsWithAuthority
    case legacyIdentityChangedDuringAudit
    case legacyIdentityIncomplete(String)
    case legacyIdentityRequiresExplicitMigration
    case legacySecureEnclaveRequiresRotationAndRepinning
    case legacyPrivateKeyNotExportableRequiresRotationAndRepinning
    case immutableGenericPasswordConflict(service: String, account: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRecordVersion(let version):
            return "Unsupported device identity authority version: \(version)"
        case .invalidDeviceId:
            return "Device identity authority contains an invalid device ID"
        case .invalidPublicKey:
            return "Device identity authority contains an invalid P-256 public key"
        case .publicKeyFingerprintMismatch:
            return "Device identity authority public-key fingerprint does not match its exact public key"
        case .invalidPrivateKeyApplicationTag:
            return "Device identity authority contains an invalid unique private-key tag"
        case .invalidCreatedAt:
            return "Device identity authority contains an invalid creation timestamp"
        case .corruptAuthorityRecord:
            return "Device identity authority record is corrupt"
        case .authorityWinnerMissing:
            return "Device identity authority was not readable after compare-and-set"
        case .authorityWinnerKeyMissing(let tag):
            return "Device identity authority references a missing private key: \(tag)"
        case .authorityWinnerPublicKeyMismatch:
            return "Device identity authority does not match the public key derived from its private key"
        case .authorityWinnerSecureEnclaveMismatch:
            return "Device identity authority Secure Enclave metadata does not match its private key"
        case .candidateKeyPublicKeyMismatch:
            return "Device identity candidate does not match its staged private key"
        case .candidateCleanupFailed(let reason):
            return "Device identity candidate cleanup failed: \(reason)"
        case .legacyIdentityConflictsWithAuthority:
            return "Legacy device identity conflicts with the shared identity authority; explicit rotation and peer re-pinning are required"
        case .legacyIdentityChangedDuringAudit:
            return "Legacy device identity storage changed during the read-only audit"
        case .legacyIdentityIncomplete(let reason):
            return "Legacy device identity is incomplete: \(reason)"
        case .legacyIdentityRequiresExplicitMigration:
            return "A legacy device identity exists and requires explicit migration into the shared identity authority"
        case .legacySecureEnclaveRequiresRotationAndRepinning:
            return "A legacy Secure Enclave identity cannot be moved into the shared app/extension namespace; explicit rotation and peer re-pinning are required"
        case .legacyPrivateKeyNotExportableRequiresRotationAndRepinning:
            return "A legacy identity private key is not exportable; explicit rotation and peer re-pinning are required"
        case let .immutableGenericPasswordConflict(service, account):
            return "Immutable shared Keychain value conflicts with its legacy migration input: \(service)/\(account)"
        }
    }
}

/// Narrow persistence seam for the key-first, add-only authority transaction.
/// Production uses Security.framework; tests use an OSAllocatedUnfairLock-backed
/// fake so process-race outcomes and cleanup are deterministic.
struct DeviceIdentityPrivateKeyMetadata: Equatable, Sendable {
    let publicKey: Data
    let isSecureEnclave: Bool
}

struct DeviceIdentityLegacyPrivateKeyCandidate: Equatable, Sendable {
    let location: LegacySecItemLocation
    let metadata: DeviceIdentityPrivateKeyMetadata
}

/// A normalized view of every fixed-tag identity remnant visible to the
/// signed process. Persistence locations remain in the Security adapter; this
/// value contains only identity-bearing data so reconciliation is deterministic
/// and independently testable.
struct DeviceIdentityLegacyState: Equatable, Sendable {
    var keyInfos: [DeviceIdentityKeyInfo] = []
    var deviceIds: [String] = []
    var privateKeyMetadata: [DeviceIdentityPrivateKeyMetadata] = []

    var isEmpty: Bool {
        keyInfos.isEmpty && deviceIds.isEmpty && privateKeyMetadata.isEmpty
    }
}

/// A secret-free comparison count used by the signed diagnostic host. It
/// deliberately carries no identity bytes, identifiers, Keychain locations,
/// or persistent references.
struct DeviceIdentityLegacyComparisonCount: Equatable, Sendable {
    let matching: Int
    let conflicting: Int

    var total: Int {
        matching + conflicting
    }
}

/// Pure reconciliation evidence. Keeping the comparison beside the validator
/// ensures diagnostics and the fail-closed startup decision cannot drift into
/// two different definitions of an identity match.
struct DeviceIdentityLegacyReconciliationAudit: Equatable, Sendable {
    let keyInfos: DeviceIdentityLegacyComparisonCount
    let deviceIds: DeviceIdentityLegacyComparisonCount
    let privateKeys: DeviceIdentityLegacyComparisonCount

    var hasConflicts: Bool {
        keyInfos.conflicting > 0
            || deviceIds.conflicting > 0
            || privateKeys.conflicting > 0
    }
}

struct DeviceIdentityAuthorityResidueResolution: Equatable, Sendable {
    let authority: DeviceIdentityAuthorityRecord
    let residueAudit: DeviceIdentityLegacyReconciliationAudit
}

enum DeviceIdentityLegacyReconciliation {
    /// Once the shared authority and its exact private key have been validated
    /// by the transaction store, legacy aliases are residue rather than voters.
    /// They are retained for rollback safety and reported without vetoing the
    /// immutable winner.
    static func resolveValidatedAuthority(
        _ authority: DeviceIdentityAuthorityRecord,
        retaining legacy: DeviceIdentityLegacyState
    ) throws -> DeviceIdentityAuthorityResidueResolution {
        DeviceIdentityAuthorityResidueResolution(
            authority: authority,
            residueAudit: try audit(legacy, against: authority)
        )
    }

    static func audit(
        _ legacy: DeviceIdentityLegacyState,
        against authority: DeviceIdentityAuthorityRecord
    ) throws -> DeviceIdentityLegacyReconciliationAudit {
        for keyInfo in legacy.keyInfos {
            try validateLegacyKeyInfo(keyInfo)
        }

        let keyInfoMatches = legacy.keyInfos.map {
            keyInfoMatchesAuthority($0, authority: authority)
        }
        let deviceIdMatches = legacy.deviceIds.map {
            $0 == authority.deviceId
        }
        let privateKeyMatches = legacy.privateKeyMetadata.map {
            privateKeyMetadataMatchesAuthority($0, authority: authority)
        }
        return DeviceIdentityLegacyReconciliationAudit(
            keyInfos: comparisonCount(for: keyInfoMatches),
            deviceIds: comparisonCount(for: deviceIdMatches),
            privateKeys: comparisonCount(for: privateKeyMatches)
        )
    }

    /// Compares legacy values with one another without electing a winner. The
    /// first validated keyInfo is a diagnostic comparison basis only; normal
    /// migration still requires every category to be present and converged.
    static func auditCoherenceWithoutAuthority(
        _ legacy: DeviceIdentityLegacyState
    ) throws -> DeviceIdentityLegacyReconciliationAudit? {
        guard let firstKeyInfo = legacy.keyInfos.first else {
            return nil
        }
        for keyInfo in legacy.keyInfos {
            try validateLegacyKeyInfo(keyInfo)
        }
        let keyInfoMatches = legacy.keyInfos.map { $0 == firstKeyInfo }
        let deviceIdMatches = legacy.deviceIds.map {
            $0 == firstKeyInfo.deviceId
        }
        let privateKeyMatches = legacy.privateKeyMetadata.map {
            $0.publicKey == firstKeyInfo.publicKey
                && $0.isSecureEnclave == firstKeyInfo.isSecureEnclave
        }
        return DeviceIdentityLegacyReconciliationAudit(
            keyInfos: comparisonCount(for: keyInfoMatches),
            deviceIds: comparisonCount(for: deviceIdMatches),
            privateKeys: comparisonCount(for: privateKeyMatches)
        )
    }

    /// Recovers the last fully committed identity written by the pre-authority
    /// implementation. That implementation persisted deviceId first, created
    /// the private key second, and wrote keyInfo last. A valid keyInfo plus its
    /// exact private key is therefore the commit record; standalone deviceId
    /// and orphan fixed-tag keys are retained as incomplete rotation residue.
    static func committedMigrationKeyInfo(
        from legacy: DeviceIdentityLegacyState
    ) throws -> DeviceIdentityKeyInfo {
        guard let firstKeyInfo = legacy.keyInfos.first else {
            throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                "a committed legacy keyInfo is required"
            )
        }
        for keyInfo in legacy.keyInfos {
            try validateLegacyKeyInfo(keyInfo)
        }
        guard legacy.keyInfos.allSatisfy({ $0 == firstKeyInfo }) else {
            throw DeviceIdentityAuthorityError
                .legacyIdentityConflictsWithAuthority
        }
        guard !firstKeyInfo.isSecureEnclave else {
            throw DeviceIdentityAuthorityError
                .legacySecureEnclaveRequiresRotationAndRepinning
        }
        return firstKeyInfo
    }

    static func uniqueCommittedMigrationPrivateKey(
        from candidates: [DeviceIdentityLegacyPrivateKeyCandidate],
        matching keyInfo: DeviceIdentityKeyInfo
    ) throws -> DeviceIdentityLegacyPrivateKeyCandidate {
        try validateLegacyKeyInfo(keyInfo)
        let matches = candidates.filter {
            $0.metadata.publicKey == keyInfo.publicKey
                && $0.metadata.isSecureEnclave == keyInfo.isSecureEnclave
        }
        guard !matches.isEmpty else {
            throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                "the committed legacy keyInfo has no matching private key"
            )
        }
        guard matches.count == 1 else {
            throw DeviceIdentityAuthorityError
                .legacyIdentityConflictsWithAuthority
        }
        return matches[0]
    }

    static func validateLegacyKeyInfo(
        _ keyInfo: DeviceIdentityKeyInfo
    ) throws {
        guard keyInfo.keyType == .p256Signing,
              !keyInfo.deviceId.isEmpty,
              keyInfo.deviceId == keyInfo.deviceId.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              keyInfo.deviceId.utf8.count <= 256,
              keyInfo.deviceId.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }),
              keyInfo.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                "keyInfo contains invalid identity metadata"
            )
        }
        do {
            _ = try P256.Signing.PublicKey(
                x963Representation: keyInfo.publicKey
            )
        } catch {
            throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                "keyInfo contains an invalid P-256 public key"
            )
        }
        guard DeviceIdentityAuthorityRecord.fingerprint(
            for: keyInfo.publicKey
        ) == keyInfo.pubKeyFP else {
            throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                "keyInfo fingerprint does not match its public key"
            )
        }
    }

    static func keyInfoMatchesAuthority(
        _ keyInfo: DeviceIdentityKeyInfo,
        authority: DeviceIdentityAuthorityRecord
    ) -> Bool {
        keyInfo.deviceId == authority.deviceId
            && keyInfo.publicKey == authority.publicKey
            && keyInfo.pubKeyFP == authority.publicKeyFingerprint
            && keyInfo.createdAt == authority.createdAt
            && keyInfo.isSecureEnclave == authority.isSecureEnclave
    }

    static func privateKeyMetadataMatchesAuthority(
        _ metadata: DeviceIdentityPrivateKeyMetadata,
        authority: DeviceIdentityAuthorityRecord
    ) -> Bool {
        metadata.publicKey == authority.publicKey
            && metadata.isSecureEnclave == authority.isSecureEnclave
    }

    private static func comparisonCount(
        for matches: [Bool]
    ) -> DeviceIdentityLegacyComparisonCount {
        let matching = matches.lazy.filter { $0 }.count
        return DeviceIdentityLegacyComparisonCount(
            matching: matching,
            conflicting: matches.count - matching
        )
    }
}

protocol DeviceIdentityAuthorityTransactionStore: Sendable {
    func loadAuthority() throws -> DeviceIdentityAuthorityRecord?
    func insertAuthorityIfAbsent(
        _ record: DeviceIdentityAuthorityRecord
    ) throws -> KeychainInsertResult
    func privateKeyMetadata(
        forPrivateKeyApplicationTag tag: String
    ) throws -> DeviceIdentityPrivateKeyMetadata?
    func insertSoftwarePrivateKeyIfAbsent(
        _ privateKeyRepresentation: Data,
        expectedPublicKey: Data,
        applicationTag: String
    ) throws -> KeychainInsertResult
    func deletePrivateKey(applicationTag: String) throws
}

enum DeviceIdentityLegacyKeyMaterial: Sendable, Equatable {
    case software(
        authority: DeviceIdentityAuthorityRecord,
        privateKeyRepresentation: Data
    )
    case secureEnclave
    case unexportable
}

/// Coordinates the two-item transaction:
/// candidate key first, immutable authority second, authoritative winner reload
/// last. A candidate is never published before the permanent key is readable.
enum DeviceIdentityAuthorityTransaction {
    static func resolve(
        using store: any DeviceIdentityAuthorityTransactionStore
    ) throws -> DeviceIdentityAuthorityRecord? {
        guard let record = try store.loadAuthority() else { return nil }
        return try validatedWinner(record, using: store)
    }

    static func claimCandidate(
        _ candidate: DeviceIdentityAuthorityRecord,
        using store: any DeviceIdentityAuthorityTransactionStore
    ) throws -> DeviceIdentityAuthorityRecord {
        let validatedCandidate = try candidate.validated()
        guard let stagedMetadata = try store.privateKeyMetadata(
            forPrivateKeyApplicationTag: validatedCandidate.privateKeyApplicationTag
        ), stagedMetadata.publicKey == validatedCandidate.publicKey,
        stagedMetadata.isSecureEnclave == validatedCandidate.isSecureEnclave else {
            try cleanupCandidate(
                applicationTag: validatedCandidate.privateKeyApplicationTag,
                using: store
            )
            throw DeviceIdentityAuthorityError.candidateKeyPublicKeyMismatch
        }

        do {
            _ = try store.insertAuthorityIfAbsent(validatedCandidate)
        } catch {
            try cleanupCandidate(
                applicationTag: validatedCandidate.privateKeyApplicationTag,
                using: store
            )
            throw error
        }

        guard let encodedWinner = try store.loadAuthority() else {
            // The candidate may be the published authority. Do not delete its
            // key when authority visibility is uncertain.
            throw DeviceIdentityAuthorityError.authorityWinnerMissing
        }
        let winner: DeviceIdentityAuthorityRecord
        do {
            winner = try validatedWinner(encodedWinner, using: store)
        } catch {
            if encodedWinner.privateKeyApplicationTag
                != validatedCandidate.privateKeyApplicationTag {
                try cleanupCandidate(
                    applicationTag: validatedCandidate.privateKeyApplicationTag,
                    using: store
                )
            }
            throw error
        }
        if winner.privateKeyApplicationTag != validatedCandidate.privateKeyApplicationTag {
            try cleanupCandidate(
                applicationTag: validatedCandidate.privateKeyApplicationTag,
                using: store
            )
        }
        return winner
    }

    static func migrateLegacy(
        _ legacy: DeviceIdentityLegacyKeyMaterial,
        candidateApplicationTag: String,
        using store: any DeviceIdentityAuthorityTransactionStore
    ) throws -> DeviceIdentityAuthorityRecord {
        switch legacy {
        case .secureEnclave:
            throw DeviceIdentityAuthorityError.legacySecureEnclaveRequiresRotationAndRepinning
        case .unexportable:
            throw DeviceIdentityAuthorityError.legacyPrivateKeyNotExportableRequiresRotationAndRepinning
        case let .software(authority, privateKeyRepresentation):
            var mutablePrivateKeyRepresentation = privateKeyRepresentation
            defer { mutablePrivateKeyRepresentation.secureErase() }
            let candidate = try DeviceIdentityAuthorityRecord(
                deviceId: authority.deviceId,
                publicKey: authority.publicKey,
                publicKeyFingerprint: authority.publicKeyFingerprint,
                privateKeyApplicationTag: candidateApplicationTag,
                isSecureEnclave: false,
                createdAt: authority.createdAt
            ).validated()
            let insertion = try store.insertSoftwarePrivateKeyIfAbsent(
                mutablePrivateKeyRepresentation,
                expectedPublicKey: candidate.publicKey,
                applicationTag: candidate.privateKeyApplicationTag
            )
            if insertion == .alreadyExists {
                guard try store.privateKeyMetadata(
                    forPrivateKeyApplicationTag: candidate.privateKeyApplicationTag
                ) == DeviceIdentityPrivateKeyMetadata(
                    publicKey: candidate.publicKey,
                    isSecureEnclave: false
                ) else {
                    throw DeviceIdentityAuthorityError.candidateKeyPublicKeyMismatch
                }
            }
            let winner = try claimCandidate(candidate, using: store)
            guard winner.deviceId == candidate.deviceId,
                  winner.publicKey == candidate.publicKey,
                  winner.publicKeyFingerprint == candidate.publicKeyFingerprint else {
                throw DeviceIdentityAuthorityError.legacyIdentityConflictsWithAuthority
            }
            return winner
        }
    }

    private static func validatedWinner(
        _ record: DeviceIdentityAuthorityRecord,
        using store: any DeviceIdentityAuthorityTransactionStore
    ) throws -> DeviceIdentityAuthorityRecord {
        let validated = try record.validated()
        guard let metadata = try store.privateKeyMetadata(
            forPrivateKeyApplicationTag: validated.privateKeyApplicationTag
        ) else {
            throw DeviceIdentityAuthorityError.authorityWinnerKeyMissing(
                validated.privateKeyApplicationTag
            )
        }
        guard metadata.publicKey == validated.publicKey,
              DeviceIdentityAuthorityRecord.fingerprint(for: metadata.publicKey)
                == validated.publicKeyFingerprint else {
            throw DeviceIdentityAuthorityError.authorityWinnerPublicKeyMismatch
        }
        guard metadata.isSecureEnclave == validated.isSecureEnclave else {
            throw DeviceIdentityAuthorityError.authorityWinnerSecureEnclaveMismatch
        }
        return validated
    }

    private static func cleanupCandidate(
        applicationTag: String,
        using store: any DeviceIdentityAuthorityTransactionStore
    ) throws {
        do {
            try store.deletePrivateKey(applicationTag: applicationTag)
        } catch {
            throw DeviceIdentityAuthorityError.candidateCleanupFailed(
                error.localizedDescription
            )
        }
    }
}

/// Security.framework implementation of the narrow authority transaction
/// store. Every authority and winner-key read is restricted to the resolved
/// shared access group; unscoped reads exist only in explicit legacy discovery.
struct DeviceIdentityKeychainAuthorityStore: DeviceIdentityAuthorityTransactionStore {
    private static let authorityService = "com.skybridge.p2p.identity.authority.v1"
    private static let authorityAccount = "active"

    let authoritativeScope: KeychainGenericPasswordScope

    init(keychainScope: KeychainGenericPasswordScope) throws {
        self.authoritativeScope = try keychainScope.authoritativeOnly()
    }

    func loadAuthority() throws -> DeviceIdentityAuthorityRecord? {
        guard let encoded = try KeychainManager.shared.exportKeyStrict(
            service: Self.authorityService,
            account: Self.authorityAccount,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) else {
            return nil
        }
        guard encoded.count <= DeviceIdentityAuthorityRecord.maximumEncodedSize else {
            throw DeviceIdentityAuthorityError.corruptAuthorityRecord
        }
        do {
            return try JSONDecoder().decode(
                DeviceIdentityAuthorityRecord.self,
                from: encoded
            )
        } catch {
            throw DeviceIdentityAuthorityError.corruptAuthorityRecord
        }
    }

    func insertAuthorityIfAbsent(
        _ record: DeviceIdentityAuthorityRecord
    ) throws -> KeychainInsertResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(record.validated())
        return try KeychainManager.shared.insertKeyIfAbsent(
            data: encoded,
            service: Self.authorityService,
            account: Self.authorityAccount,
            scope: authoritativeScope
        )
    }

    func privateKeyMetadata(
        forPrivateKeyApplicationTag tag: String
    ) throws -> DeviceIdentityPrivateKeyMetadata? {
        guard let key = try loadPrivateKey(
            applicationTag: tag,
            accessGroup: authoritativeScope.writeAccessGroup,
            usesDataProtectionKeychain: authoritativeScope.usesDataProtectionKeychain
        ) else {
            return nil
        }
        return try metadata(for: key)
    }

    func insertSoftwarePrivateKeyIfAbsent(
        _ privateKeyRepresentation: Data,
        expectedPublicKey: Data,
        applicationTag: String
    ) throws -> KeychainInsertResult {
        guard !privateKeyRepresentation.isEmpty else {
            throw DeviceIdentityAuthorityError.legacyPrivateKeyNotExportableRequiresRotationAndRepinning
        }
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(applicationTag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrIsPermanent as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecValueData as String: privateKeyRepresentation
        ]
        applyAccessGroup(authoritativeScope.writeAccessGroup, to: &query)
        applyDataProtectionKeychain(
            authoritativeScope.usesDataProtectionKeychain,
            to: &query
        )
        let result: KeychainInsertResult
        switch SecItemAdd(query as CFDictionary, nil) {
        case errSecSuccess:
            result = .inserted
        case errSecDuplicateItem:
            result = .alreadyExists
        case let status:
            throw DeviceIdentityKeyError.keychainError(status)
        }

        let metadata: DeviceIdentityPrivateKeyMetadata?
        do {
            metadata = try privateKeyMetadata(
                forPrivateKeyApplicationTag: applicationTag
            )
        } catch {
            if result == .inserted {
                try cleanupInsertedPrivateKey(applicationTag: applicationTag)
            }
            throw error
        }
        guard metadata == DeviceIdentityPrivateKeyMetadata(
            publicKey: expectedPublicKey,
            isSecureEnclave: false
        ) else {
            if result == .inserted {
                try cleanupInsertedPrivateKey(applicationTag: applicationTag)
            }
            throw DeviceIdentityAuthorityError.candidateKeyPublicKeyMismatch
        }
        return result
    }

    func deletePrivateKey(applicationTag: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(applicationTag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        applyAccessGroup(authoritativeScope.writeAccessGroup, to: &query)
        applyDataProtectionKeychain(
            authoritativeScope.usesDataProtectionKeychain,
            to: &query
        )
        forbidAuthenticationUI(&query)
        switch SecItemDelete(query as CFDictionary) {
        case errSecSuccess, errSecItemNotFound:
            return
        case let status:
            throw DeviceIdentityKeyError.keychainError(status)
        }
    }

    func createRandomPrivateKey(
        applicationTag: String,
        useSecureEnclave: Bool
    ) throws -> SecKey {
        var privateAttributes: [String: Any] = [
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Data(applicationTag.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        applyAccessGroup(authoritativeScope.writeAccessGroup, to: &privateAttributes)

        var attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrApplicationTag as String: Data(applicationTag.utf8),
            kSecPrivateKeyAttrs as String: privateAttributes
        ]
        applyAccessGroup(authoritativeScope.writeAccessGroup, to: &attributes)
        applyDataProtectionKeychain(
            authoritativeScope.usesDataProtectionKeychain,
            to: &attributes
        )

        if useSecureEnclave {
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                kCFAllocatorDefault,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                .privateKeyUsage,
                &accessError
            ) else {
                let reason = accessError?.takeRetainedValue().localizedDescription
                    ?? "Secure Enclave access control creation failed"
                throw DeviceIdentityKeyError.keyGenerationFailed(reason)
            }
            privateAttributes.removeValue(forKey: kSecAttrAccessible as String)
            privateAttributes[kSecAttrAccessControl as String] = access
            attributes[kSecPrivateKeyAttrs as String] = privateAttributes
            attributes[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }

        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            let retainedError = error?.takeRetainedValue()
            if useSecureEnclave,
               let retainedError,
               CFErrorGetDomain(retainedError) as String == NSOSStatusErrorDomain,
               [
                   Int(errSecMissingEntitlement),
                   Int(errSecNotAvailable),
                   Int(errSecUnimplemented)
               ].contains(CFErrorGetCode(retainedError)) {
                throw DeviceIdentityKeyError.secureEnclaveNotAvailable
            }
            throw DeviceIdentityKeyError.keyGenerationFailed(
                retainedError?.localizedDescription ?? "Unknown error"
            )
        }
        return key
    }

    func loadAuthoritativePrivateKey(applicationTag: String) throws -> SecKey? {
        try loadPrivateKey(
            applicationTag: applicationTag,
            accessGroup: authoritativeScope.writeAccessGroup,
            usesDataProtectionKeychain: authoritativeScope.usesDataProtectionKeychain
        )
    }

    func loadLegacyPrivateKeyCandidates(
        applicationTag: String
    ) throws -> [DeviceIdentityLegacyPrivateKeyCandidate] {
        var candidates: [DeviceIdentityLegacyPrivateKeyCandidate] = []
        var seenLocations = Set<LegacySecItemLocation>()
        for usesDataProtection in legacyKeychainSearchModes {
            var query: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: Data(applicationTag.utf8),
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecReturnAttributes as String: true,
                kSecReturnPersistentRef as String: true,
                kSecMatchLimit as String: kSecMatchLimitAll
            ]
            // This is the only deliberately unscoped private-key query. It is
            // discovery-only: every result must return an exact persistent ref
            // before it can be reloaded or deleted.
            applyDataProtectionKeychain(usesDataProtection, to: &query)
            forbidAuthenticationUI(&query)

            var result: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecItemNotFound:
                continue
            case errSecSuccess:
                break
            case let status:
                throw DeviceIdentityKeyError.keychainError(status)
            }
            let rows: [[String: Any]]
            if let values = result as? [[String: Any]] {
                rows = values
            } else if let value = result as? [String: Any] {
                rows = [value]
            } else {
                throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                    "fixed-tag key discovery returned malformed attributes"
                )
            }

            for row in rows {
                guard let persistentReference = row[
                    kSecValuePersistentRef as String
                ] as? Data, !persistentReference.isEmpty else {
                    throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                        "fixed-tag key discovery omitted its persistent reference"
                    )
                }
                let actualAccessGroup = row[kSecAttrAccessGroup as String] as? String
                if usesDataProtection {
                    guard let actualAccessGroup,
                          !actualAccessGroup.trimmingCharacters(
                              in: .whitespacesAndNewlines
                          ).isEmpty else {
                        throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                            "Data Protection fixed-tag key omitted its actual access group"
                        )
                    }
                }
                let location = LegacySecItemLocation(
                    actualAccessGroup: actualAccessGroup,
                    usesDataProtectionKeychain: usesDataProtection,
                    persistentReference: persistentReference
                )
                guard seenLocations.insert(location).inserted else {
                    continue
                }
                guard let key = try loadPrivateKey(at: location) else {
                    throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                        "fixed-tag key disappeared during reconciliation"
                    )
                }
                candidates.append(
                    DeviceIdentityLegacyPrivateKeyCandidate(
                        location: location,
                        metadata: try metadata(for: key)
                    )
                )
            }
        }
        return candidates.sorted {
            $0.location.isOrderedBefore($1.location)
        }
    }

    func exportLegacyPrivateKey(
        _ candidate: DeviceIdentityLegacyPrivateKeyCandidate
    ) throws -> Data {
        guard let key = try loadPrivateKey(at: candidate.location) else {
            throw DeviceIdentityAuthorityError.legacyIdentityIncomplete(
                "fixed-tag key disappeared before migration"
            )
        }
        guard try metadata(for: key) == candidate.metadata else {
            throw DeviceIdentityAuthorityError
                .legacyIdentityConflictsWithAuthority
        }
        var exportError: Unmanaged<CFError>?
        guard let privateKeyRepresentation = SecKeyCopyExternalRepresentation(
            key,
            &exportError
        ) as Data? else {
            _ = exportError?.takeRetainedValue()
            throw DeviceIdentityAuthorityError
                .legacyPrivateKeyNotExportableRequiresRotationAndRepinning
        }
        return privateKeyRepresentation
    }

    private func loadPrivateKey(
        applicationTag: String,
        accessGroup: String?,
        usesDataProtectionKeychain: Bool
    ) throws -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(applicationTag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        applyAccessGroup(accessGroup, to: &query)
        applyDataProtectionKeychain(usesDataProtectionKeychain, to: &query)
        forbidAuthenticationUI(&query)

        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
                throw DeviceIdentityKeyError.keychainError(errSecInternalError)
            }
            return unsafeDowncast(result, to: SecKey.self)
        case let status:
            throw DeviceIdentityKeyError.keychainError(status)
        }
    }

    private func loadPrivateKey(
        at location: LegacySecItemLocation
    ) throws -> SecKey? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        location.applyPersistentReferenceMatch(to: &query)
        applyDataProtectionKeychain(
            location.usesDataProtectionKeychain,
            to: &query
        )
        forbidAuthenticationUI(&query)

        var result: CFTypeRef?
        switch SecItemCopyMatching(query as CFDictionary, &result) {
        case errSecItemNotFound:
            return nil
        case errSecSuccess:
            guard let result, CFGetTypeID(result) == SecKeyGetTypeID() else {
                throw DeviceIdentityKeyError.keychainError(errSecInternalError)
            }
            return unsafeDowncast(result, to: SecKey.self)
        case let status:
            throw DeviceIdentityKeyError.keychainError(status)
        }
    }

    func metadata(for privateKey: SecKey) throws -> DeviceIdentityPrivateKeyMetadata {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw DeviceIdentityAuthorityError.invalidPublicKey
        }
        var error: Unmanaged<CFError>?
        guard let publicKeyData = SecKeyCopyExternalRepresentation(
            publicKey,
            &error
        ) as Data? else {
            throw DeviceIdentityKeyError.keyGenerationFailed(
                error?.takeRetainedValue().localizedDescription
                    ?? "P-256 public-key export failed"
            )
        }
        let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any]
        guard let attributes,
              (attributes[kSecAttrKeyType as String] as? String)
                == (kSecAttrKeyTypeECSECPrimeRandom as String),
              (attributes[kSecAttrKeyClass as String] as? String)
                == (kSecAttrKeyClassPrivate as String),
              (attributes[kSecAttrKeySizeInBits as String] as? NSNumber)?.intValue == 256 else {
            throw DeviceIdentityAuthorityError.invalidPublicKey
        }
        let tokenID = attributes[kSecAttrTokenID as String]
        let isSecureEnclave = (tokenID as? String)
            == (kSecAttrTokenIDSecureEnclave as String)
        return DeviceIdentityPrivateKeyMetadata(
            publicKey: publicKeyData,
            isSecureEnclave: isSecureEnclave
        )
    }

    private func applyAccessGroup(
        _ accessGroup: String?,
        to query: inout [String: Any]
    ) {
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        } else {
            query.removeValue(forKey: kSecAttrAccessGroup as String)
        }
    }

    private func applyDataProtectionKeychain(
        _ enabled: Bool,
        to query: inout [String: Any]
    ) {
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = enabled
        #else
        _ = enabled
        #endif
    }

    private func forbidAuthenticationUI(_ query: inout [String: Any]) {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
    }

    private func cleanupInsertedPrivateKey(applicationTag: String) throws {
        do {
            try deletePrivateKey(applicationTag: applicationTag)
        } catch {
            throw DeviceIdentityAuthorityError.candidateCleanupFailed(
                error.localizedDescription
            )
        }
    }

    private var legacyKeychainSearchModes: [Bool] {
        #if os(macOS)
        [true, false]
        #else
        [true]
        #endif
    }
}

/// A callback is bound to the actor's resolved authority path. It cannot issue
/// a tag-only Keychain query that omits the shared access group.
struct DeviceIdentityManagerSigningCallback: SigningCallback, Sendable {
    private let signer: @Sendable (Data) async throws -> Data

    init(manager: DeviceIdentityKeyManager) {
        signer = { data in
            try await manager.sign(data: data)
        }
    }

    #if DEBUG || SKYBRIDGE_TESTING
    init(signer: @escaping @Sendable (Data) async throws -> Data) {
        self.signer = signer
    }
    #endif

    func sign(data: Data) async throws -> Data {
        try await signer(data)
    }
}
