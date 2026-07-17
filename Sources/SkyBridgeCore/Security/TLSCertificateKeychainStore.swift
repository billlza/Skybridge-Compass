import CryptoKit
import Foundation
import Security
import os

/// Observable failures for the TLS certificate lifecycle. Mutating callers
/// must surface these errors instead of collapsing Keychain failures to a
/// Boolean or replacing an existing identity.
public enum TLSCertificateLifecycleError: Error, LocalizedError, Sendable, Equatable {
    case invalidDeviceId
    case missingSharedKeychainAccessGroup
    case memoryOnlyPKCS12ImportUnavailable
    case invalidPKCS12Input(reason: String)
    case pkcs12ImportFailed(status: OSStatus)
    case invalidPKCS12Container(identityCount: Int)
    case candidateIdentityInvalid
    case keyGenerationFailed
    case certificateGenerationFailed
    case canonicalIdentityIncomplete
    case canonicalIdentityAmbiguous
    case legacyOrDefaultKeychainConflict
    case rotationRequired
    case keychainOperationFailed(operation: String, status: OSStatus)
    case persistentReferenceMissing(operation: String)
    case rollbackFailed(
        primaryContext: String,
        cleanupFailures: [TLSCertificateCleanupFailure]
    )
    case issuedCertificateImportUnavailable
    case identityUnavailable
    case invalidCSRInput(reason: String)
    case csrGenerationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidDeviceId:
            return "TLS certificate device identity is invalid"
        case .missingSharedKeychainAccessGroup:
            return "The signed process is missing the shared TLS identity Keychain access group"
        case .memoryOnlyPKCS12ImportUnavailable:
            return "PKCS#12 import is unavailable because this OS cannot guarantee a memory-only import"
        case .invalidPKCS12Input(let reason):
            return "PKCS#12 input is invalid: \(reason)"
        case .pkcs12ImportFailed(let status):
            return "PKCS#12 memory-only import failed with Security status \(status)"
        case .invalidPKCS12Container(let identityCount):
            return "PKCS#12 must contain exactly one identity; found \(identityCount)"
        case .candidateIdentityInvalid:
            return "The certificate and private key do not form one valid identity"
        case .keyGenerationFailed:
            return "TLS private-key generation failed"
        case .certificateGenerationFailed:
            return "TLS certificate generation failed"
        case .canonicalIdentityIncomplete:
            return "The canonical TLS identity is only partially present"
        case .canonicalIdentityAmbiguous:
            return "The canonical TLS identity contains duplicate key or certificate records"
        case .legacyOrDefaultKeychainConflict:
            return "A legacy or default-Keychain TLS identity conflicts with the canonical shared identity"
        case .rotationRequired:
            return "A different TLS identity already exists; explicit authenticated rotation is required"
        case .keychainOperationFailed(let operation, let status):
            return "TLS Keychain operation \(operation) failed with Security status \(status)"
        case .persistentReferenceMissing(let operation):
            return "TLS Keychain operation \(operation) did not return a persistent reference"
        case .rollbackFailed(let primaryContext, let cleanupFailures):
            let summary = cleanupFailures
                .map { "\($0.operation)=\($0.status)" }
                .joined(separator: ",")
            return "TLS Keychain rollback failed after \(primaryContext): \(summary)"
        case .issuedCertificateImportUnavailable:
            return "Issued-certificate import requires an authenticated certificate/private-key replacement transaction"
        case .identityUnavailable:
            return "No canonical TLS identity is available for this device"
        case .invalidCSRInput(let reason):
            return "TLS certificate-signing request input is invalid: \(reason)"
        case .csrGenerationFailed:
            return "TLS certificate-signing request generation failed"
        }
    }
}

enum TLSCertificateLifecycleLimits {
    static let maximumPKCS12Bytes = 16 * 1_024 * 1_024
    static let maximumPKCS12PasswordUTF8Bytes = 4 * 1_024
}

public struct TLSCertificateCleanupFailure: Sendable, Equatable {
    public let operation: String
    public let status: OSStatus

    init(operation: String, status: OSStatus) {
        self.operation = operation
        self.status = status
    }
}

struct TLSCertificateCandidate {
    let certificate: SecCertificate
    let privateKey: SecKey
}

struct TLSCertificateIdentityRecord {
    let certificate: SecCertificate
    let privateKey: SecKey
    let identity: SecIdentity
}

struct TLSCertificateRollbackItem: Sendable, Equatable {
    let operation: String
    let itemClass: String
    let persistentReference: Data
}

/// Pure coordination seam used by the Security.framework adapter and unit
/// tests. Cleanup always attempts every inserted item before reporting the
/// aggregate failure.
enum TLSCertificateRollbackCoordinator {
    static func requirePersistentReference(
        _ persistentReference: Data?,
        operation: String,
        exactDelete: () -> OSStatus
    ) throws -> Data {
        if let persistentReference, !persistentReference.isEmpty {
            return persistentReference
        }

        let cleanupStatus = exactDelete()
        guard cleanupStatus == errSecSuccess
                || cleanupStatus == errSecItemNotFound else {
            throw TLSCertificateLifecycleError.rollbackFailed(
                primaryContext: "\(operation):missing-persistent-reference",
                cleanupFailures: [
                    TLSCertificateCleanupFailure(
                        operation: operation,
                        status: cleanupStatus
                    )
                ]
            )
        }
        throw TLSCertificateLifecycleError.persistentReferenceMissing(
            operation: operation
        )
    }

    static func cleanup(
        primaryContext: String,
        items: [TLSCertificateRollbackItem],
        delete: (TLSCertificateRollbackItem) -> OSStatus
    ) throws {
        var failures: [TLSCertificateCleanupFailure] = []
        for item in items {
            let status = delete(item)
            if status != errSecSuccess && status != errSecItemNotFound {
                failures.append(
                    TLSCertificateCleanupFailure(
                        operation: item.operation,
                        status: status
                    )
                )
            }
        }
        guard failures.isEmpty else {
            throw TLSCertificateLifecycleError.rollbackFailed(
                primaryContext: primaryContext,
                cleanupFailures: failures
            )
        }
    }
}

/// The single Security.framework storage boundary for TLS identities.
///
/// The process-wide unfair lock is available on the package's macOS 14 and
/// iOS 17 deployment floors. Keychain create-only writes remain the
/// cross-process contention boundary; the lock prevents two local managers
/// from interleaving preflight, write, reload, and rollback.
struct TLSCertificateKeychainStore {
    private struct Scope {
        let accessGroup: String
    }

    private static let transactionLock = OSAllocatedUnfairLock<Void>(
        initialState: ()
    )

    // Security.framework references are deliberately lock-confined and never
    // stored in Sendable state. `withLockUnchecked` is the standard-library
    // entry point for a synchronous non-Sendable result; public detached
    // wrappers discard CF references and return only Void or String.

    static func validatedDeviceId(_ raw: String) throws -> String {
        do {
            return try TLSConnectionIdentityContext.validatedDeviceId(raw)
        } catch {
            throw TLSCertificateLifecycleError.invalidDeviceId
        }
    }

    func identity(for rawDeviceId: String) throws -> TLSCertificateIdentityRecord? {
        let deviceId = try Self.validatedDeviceId(rawDeviceId)
        let scope = try resolvedScope()
        return try Self.transactionLock.withLockUnchecked { _ in
            try loadCanonicalIdentity(deviceId: deviceId, scope: scope)
        }
    }

    func getOrCreateIdentity(
        for rawDeviceId: String,
        candidateProvider: () throws -> TLSCertificateCandidate
    ) throws -> TLSCertificateIdentityRecord {
        let deviceId = try Self.validatedDeviceId(rawDeviceId)
        let scope = try resolvedScope()
        return try Self.transactionLock.withLockUnchecked { _ in
            if let existing = try loadCanonicalIdentity(
                deviceId: deviceId,
                scope: scope
            ) {
                return existing
            }

            let candidate = try candidateProvider()
            let persisted = try persistCreateOnly(
                candidate,
                deviceId: deviceId,
                scope: scope
            )
            return persisted
        }
    }

    func importIdentity(
        _ candidate: TLSCertificateCandidate,
        for rawDeviceId: String
    ) throws -> TLSCertificateIdentityRecord {
        let deviceId = try Self.validatedDeviceId(rawDeviceId)
        try validate(candidate: candidate)
        let scope = try resolvedScope()
        return try Self.transactionLock.withLockUnchecked { _ in
            if let existing = try loadCanonicalIdentity(
                deviceId: deviceId,
                scope: scope
            ) {
                guard identitiesMatch(existing, candidate) else {
                    throw TLSCertificateLifecycleError.rotationRequired
                }
                return existing
            }

            let persisted = try persistCreateOnly(
                candidate,
                deviceId: deviceId,
                scope: scope
            )
            return persisted
        }
    }

    private func resolvedScope() throws -> Scope {
        do {
            return Scope(
                accessGroup: try SkyBridgeKeychainAccessGroupResolver
                    .requiredSharedAccessGroup()
            )
        } catch {
            throw TLSCertificateLifecycleError.missingSharedKeychainAccessGroup
        }
    }

    private func canonicalLabel(for deviceId: String) -> String {
        let digest = SHA256.hash(data: Data(deviceId.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return "com.skybridge.compass.tls.identity.v2.\(digest)"
    }

    private func canonicalPrivateKeyTag(for deviceId: String) -> Data {
        Data(canonicalLabel(for: deviceId).utf8)
    }

    private func legacyLabel(for deviceId: String) -> String {
        "SkyBridge.\(deviceId)"
    }

    private func loadCanonicalIdentity(
        deviceId: String,
        scope: Scope
    ) throws -> TLSCertificateIdentityRecord? {
        try rejectLegacyOrDefaultConflicts(deviceId: deviceId, scope: scope)

        let certificates = try canonicalCertificates(
            deviceId: deviceId,
            scope: scope
        )
        let privateKeys = try canonicalPrivateKeys(
            deviceId: deviceId,
            scope: scope
        )

        guard certificates.count <= 1, privateKeys.count <= 1 else {
            throw TLSCertificateLifecycleError.canonicalIdentityAmbiguous
        }
        guard certificates.count == privateKeys.count else {
            throw TLSCertificateLifecycleError.canonicalIdentityIncomplete
        }
        guard let certificate = certificates.first,
              let privateKey = privateKeys.first else {
            return nil
        }
        return try makeValidatedIdentity(
            certificate: certificate,
            privateKey: privateKey
        )
    }

    private func persistCreateOnly(
        _ candidate: TLSCertificateCandidate,
        deviceId: String,
        scope: Scope
    ) throws -> TLSCertificateIdentityRecord {
        try validate(candidate: candidate)

        let keyPersistentReference: Data
        do {
            keyPersistentReference = try addPrivateKey(
                candidate.privateKey,
                deviceId: deviceId,
                scope: scope
            )
        } catch TLSCertificateLifecycleError.keychainOperationFailed(
            operation: _,
            status: errSecDuplicateItem
        ) {
            guard let existing = try loadCanonicalIdentity(
                deviceId: deviceId,
                scope: scope
            ) else {
                throw TLSCertificateLifecycleError.canonicalIdentityIncomplete
            }
            guard identitiesMatch(existing, candidate) else {
                throw TLSCertificateLifecycleError.rotationRequired
            }
            return existing
        }

        let certificatePersistentReference: Data
        do {
            certificatePersistentReference = try addCertificate(
                candidate.certificate,
                deviceId: deviceId,
                scope: scope
            )
        } catch {
            try cleanupAndRethrow(
                primaryError: error,
                items: [
                    TLSCertificateRollbackItem(
                        operation: "private-key",
                        itemClass: "key",
                        persistentReference: keyPersistentReference
                    )
                ]
            )
        }

        do {
            let reloadedCertificate = try loadCertificate(
                persistentReference: certificatePersistentReference
            )
            let reloadedPrivateKey = try loadPrivateKey(
                persistentReference: keyPersistentReference
            )
            let reloaded = try makeValidatedIdentity(
                certificate: reloadedCertificate,
                privateKey: reloadedPrivateKey
            )
            guard identitiesMatch(reloaded, candidate) else {
                throw TLSCertificateLifecycleError.candidateIdentityInvalid
            }

            guard let canonical = try loadCanonicalIdentity(
                deviceId: deviceId,
                scope: scope
            ), identitiesMatch(canonical, candidate) else {
                throw TLSCertificateLifecycleError.candidateIdentityInvalid
            }
            return canonical
        } catch {
            let primaryError = error
            try cleanupAndRethrow(
                primaryError: primaryError,
                items: [
                    TLSCertificateRollbackItem(
                        operation: "certificate",
                        itemClass: "certificate",
                        persistentReference: certificatePersistentReference
                    ),
                    TLSCertificateRollbackItem(
                        operation: "private-key",
                        itemClass: "key",
                        persistentReference: keyPersistentReference
                    )
                ]
            )
        }
    }

    private func validate(candidate: TLSCertificateCandidate) throws {
        _ = try makeValidatedIdentity(
            certificate: candidate.certificate,
            privateKey: candidate.privateKey
        )
    }

    private func makeValidatedIdentity(
        certificate: SecCertificate,
        privateKey: SecKey
    ) throws -> TLSCertificateIdentityRecord {
        guard keysMatch(certificate: certificate, privateKey: privateKey),
              let identity = SecIdentityCreate(nil, certificate, privateKey) else {
            throw TLSCertificateLifecycleError.candidateIdentityInvalid
        }

        var identityCertificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &identityCertificate) == errSecSuccess,
              let identityCertificate,
              certificateDER(identityCertificate) == certificateDER(certificate) else {
            throw TLSCertificateLifecycleError.candidateIdentityInvalid
        }

        var identityPrivateKey: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &identityPrivateKey) == errSecSuccess,
              let identityPrivateKey,
              publicKeyData(identityPrivateKey) == publicKeyData(privateKey) else {
            throw TLSCertificateLifecycleError.candidateIdentityInvalid
        }

        return TLSCertificateIdentityRecord(
            certificate: certificate,
            privateKey: privateKey,
            identity: identity
        )
    }

    private func identitiesMatch(
        _ existing: TLSCertificateIdentityRecord,
        _ candidate: TLSCertificateCandidate
    ) -> Bool {
        certificateDER(existing.certificate) == certificateDER(candidate.certificate)
            && publicKeyData(existing.privateKey) == publicKeyData(candidate.privateKey)
    }

    private func keysMatch(
        certificate: SecCertificate,
        privateKey: SecKey
    ) -> Bool {
        guard let certificatePublicKey = SecCertificateCopyKey(certificate),
              let privatePublicKey = SecKeyCopyPublicKey(privateKey),
              let certificatePublicData = SecKeyCopyExternalRepresentation(
                  certificatePublicKey,
                  nil
              ) as Data?,
              let privatePublicData = SecKeyCopyExternalRepresentation(
                  privatePublicKey,
                  nil
              ) as Data? else {
            return false
        }
        return certificatePublicData == privatePublicData
    }

    private func publicKeyData(_ privateKey: SecKey) -> Data? {
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else { return nil }
        return SecKeyCopyExternalRepresentation(publicKey, nil) as Data?
    }

    private func certificateDER(_ certificate: SecCertificate) -> Data {
        SecCertificateCopyData(certificate) as Data
    }

    private func addPrivateKey(
        _ privateKey: SecKey,
        deviceId: String,
        scope: Scope
    ) throws -> Data {
        guard let attributes = SecKeyCopyAttributes(privateKey) as? [String: Any],
              let keyType = attributes[kSecAttrKeyType as String],
              let keySize = attributes[kSecAttrKeySizeInBits as String] else {
            throw TLSCertificateLifecycleError.candidateIdentityInvalid
        }

        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeyType as String: keyType,
            kSecAttrKeySizeInBits as String: keySize,
            kSecAttrApplicationTag as String: canonicalPrivateKeyTag(for: deviceId),
            kSecAttrLabel as String: canonicalLabel(for: deviceId),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: scope.accessGroup,
            kSecValueRef as String: privateKey,
            kSecReturnPersistentRef as String: true
        ]
        applyDataProtectionKeychain(to: &query)
        var exactMatchQuery = canonicalQuery(
            itemClass: kSecClassKey,
            scope: scope
        )
        exactMatchQuery[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
        exactMatchQuery[kSecAttrApplicationTag as String] =
            canonicalPrivateKeyTag(for: deviceId)
        return try addPersistentItem(
            query,
            exactMatchQuery: exactMatchQuery,
            operation: "add-private-key"
        )
    }

    private func addCertificate(
        _ certificate: SecCertificate,
        deviceId: String,
        scope: Scope
    ) throws -> Data {
        var query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: canonicalLabel(for: deviceId),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: scope.accessGroup,
            kSecValueRef as String: certificate,
            kSecReturnPersistentRef as String: true
        ]
        applyDataProtectionKeychain(to: &query)
        var exactMatchQuery = canonicalQuery(
            itemClass: kSecClassCertificate,
            scope: scope
        )
        applyTransientReferenceMatch(certificate, to: &exactMatchQuery)
        return try addPersistentItem(
            query,
            exactMatchQuery: exactMatchQuery,
            operation: "add-certificate"
        )
    }

    private func addPersistentItem(
        _ query: [String: Any],
        exactMatchQuery: [String: Any],
        operation: String
    ) throws -> Data {
        var result: CFTypeRef?
        let status = SecItemAdd(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            throw TLSCertificateLifecycleError.keychainOperationFailed(
                operation: operation,
                status: status
            )
        }
        if let persistentReference = result as? Data,
           !persistentReference.isEmpty {
            return persistentReference
        }

        var recoveryQuery = exactMatchQuery
        recoveryQuery[kSecReturnPersistentRef as String] = true
        recoveryQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var recoveredResult: CFTypeRef?
        let recoveryStatus = SecItemCopyMatching(
            recoveryQuery as CFDictionary,
            &recoveredResult
        )
        if recoveryStatus == errSecSuccess,
           let recoveredReference = recoveredResult as? Data,
           !recoveredReference.isEmpty {
            return recoveredReference
        }

        return try TLSCertificateRollbackCoordinator.requirePersistentReference(
            nil,
            operation: operation,
            exactDelete: {
                SecItemDelete(exactMatchQuery as CFDictionary)
            }
        )
    }

    private func canonicalCertificates(
        deviceId: String,
        scope: Scope
    ) throws -> [SecCertificate] {
        var query = canonicalQuery(
            itemClass: kSecClassCertificate,
            scope: scope
        )
        query[kSecAttrLabel as String] = canonicalLabel(for: deviceId)
        return try copyAllReferences(
            query,
            expectedTypeID: SecCertificateGetTypeID(),
            operation: "load-canonical-certificates"
        ).map { unsafeDowncast($0, to: SecCertificate.self) }
    }

    private func canonicalPrivateKeys(
        deviceId: String,
        scope: Scope
    ) throws -> [SecKey] {
        var query = canonicalQuery(itemClass: kSecClassKey, scope: scope)
        query[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
        query[kSecAttrApplicationTag as String] = canonicalPrivateKeyTag(
            for: deviceId
        )
        return try copyAllReferences(
            query,
            expectedTypeID: SecKeyGetTypeID(),
            operation: "load-canonical-private-keys"
        ).map { unsafeDowncast($0, to: SecKey.self) }
    }

    private func canonicalQuery(
        itemClass: CFTypeRef,
        scope: Scope
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecAttrSynchronizable as String: false,
            kSecAttrAccessGroup as String: scope.accessGroup
        ]
        applyDataProtectionKeychain(to: &query)
        return query
    }

    private func copyAllReferences(
        _ baseQuery: [String: Any],
        expectedTypeID: CFTypeID,
        operation: String
    ) throws -> [AnyObject] {
        var query = baseQuery
        query[kSecReturnRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else {
            throw TLSCertificateLifecycleError.keychainOperationFailed(
                operation: operation,
                status: status
            )
        }
        guard let references = result as? [AnyObject],
              references.allSatisfy({ CFGetTypeID($0) == expectedTypeID }) else {
            throw TLSCertificateLifecycleError.keychainOperationFailed(
                operation: operation,
                status: errSecInternalError
            )
        }
        return references
    }

    private func rejectLegacyOrDefaultConflicts(
        deviceId: String,
        scope: Scope
    ) throws {
        let canonicalLabel = canonicalLabel(for: deviceId)
        let legacyLabel = legacyLabel(for: deviceId)
        let legacyKeyTag = Data(legacyLabel.utf8)

        for usesDataProtectionKeychain in discoveryDomains {
            let canonicalCertificateGroups = try discoveredAccessGroups(
                itemClass: kSecClassCertificate,
                isPrivateKey: false,
                selectorKey: kSecAttrLabel,
                selectorValue: canonicalLabel,
                usesDataProtectionKeychain: usesDataProtectionKeychain,
                operation: "discover-canonical-certificate-conflicts"
            )
            let canonicalKeyGroups = try discoveredAccessGroups(
                itemClass: kSecClassKey,
                isPrivateKey: true,
                selectorKey: kSecAttrApplicationTag,
                selectorValue: canonicalPrivateKeyTag(for: deviceId),
                usesDataProtectionKeychain: usesDataProtectionKeychain,
                operation: "discover-canonical-key-conflicts"
            )
            let legacyCertificateGroups = try discoveredAccessGroups(
                itemClass: kSecClassCertificate,
                isPrivateKey: false,
                selectorKey: kSecAttrLabel,
                selectorValue: legacyLabel,
                usesDataProtectionKeychain: usesDataProtectionKeychain,
                operation: "discover-legacy-certificate-conflicts"
            )
            let legacyKeyGroups = try discoveredAccessGroups(
                itemClass: kSecClassKey,
                isPrivateKey: true,
                selectorKey: kSecAttrApplicationTag,
                selectorValue: legacyKeyTag,
                usesDataProtectionKeychain: usesDataProtectionKeychain,
                operation: "discover-legacy-key-conflicts"
            )

            let canonicalScopeIsExpected = usesDataProtectionKeychain
                && canonicalCertificateGroups.allSatisfy { $0 == scope.accessGroup }
                && canonicalKeyGroups.allSatisfy { $0 == scope.accessGroup }
            let hasCanonicalItems = !canonicalCertificateGroups.isEmpty
                || !canonicalKeyGroups.isEmpty
            if hasCanonicalItems && !canonicalScopeIsExpected {
                throw TLSCertificateLifecycleError.legacyOrDefaultKeychainConflict
            }
            if !legacyCertificateGroups.isEmpty || !legacyKeyGroups.isEmpty {
                throw TLSCertificateLifecycleError.legacyOrDefaultKeychainConflict
            }
        }
    }

    private var discoveryDomains: [Bool] {
        #if os(macOS)
        [true, false]
        #else
        [true]
        #endif
    }

    private func discoveredAccessGroups(
        itemClass: CFTypeRef,
        isPrivateKey: Bool,
        selectorKey: CFString,
        selectorValue: Any,
        usesDataProtectionKeychain: Bool,
        operation: String
    ) throws -> [String?] {
        var query: [String: Any] = [
            kSecClass as String: itemClass,
            selectorKey as String: selectorValue,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        if isPrivateKey {
            query[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
        }
        applyDataProtectionKeychain(
            usesDataProtectionKeychain,
            to: &query
        )

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess,
              let rows = result as? [[String: Any]] else {
            throw TLSCertificateLifecycleError.keychainOperationFailed(
                operation: operation,
                status: status == errSecSuccess ? errSecInternalError : status
            )
        }
        return rows.map { $0[kSecAttrAccessGroup as String] as? String }
    }

    private func loadCertificate(
        persistentReference: Data
    ) throws -> SecCertificate {
        let reference = try loadReference(
            persistentReference: persistentReference,
            itemClass: kSecClassCertificate,
            expectedTypeID: SecCertificateGetTypeID(),
            operation: "reload-certificate"
        )
        return unsafeDowncast(reference, to: SecCertificate.self)
    }

    private func loadPrivateKey(
        persistentReference: Data
    ) throws -> SecKey {
        let reference = try loadReference(
            persistentReference: persistentReference,
            itemClass: kSecClassKey,
            expectedTypeID: SecKeyGetTypeID(),
            operation: "reload-private-key"
        )
        return unsafeDowncast(reference, to: SecKey.self)
    }

    private func loadReference(
        persistentReference: Data,
        itemClass: CFTypeRef,
        expectedTypeID: CFTypeID,
        operation: String
    ) throws -> AnyObject {
        var query: [String: Any] = [
            kSecClass as String: itemClass,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        applyDataProtectionKeychain(to: &query)
        applyPersistentReference(persistentReference, to: &query)
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let result,
              CFGetTypeID(result) == expectedTypeID else {
            throw TLSCertificateLifecycleError.keychainOperationFailed(
                operation: operation,
                status: status == errSecSuccess ? errSecInternalError : status
            )
        }
        return result
    }

    private func cleanupAndRethrow(
        primaryError: Error,
        items: [TLSCertificateRollbackItem]
    ) throws -> Never {
        do {
            try TLSCertificateRollbackCoordinator.cleanup(
                primaryContext: String(describing: primaryError),
                items: items,
                delete: deleteExactStatus
            )
        } catch {
            throw error
        }
        throw primaryError
    }

    private func deleteExactStatus(
        _ item: TLSCertificateRollbackItem
    ) -> OSStatus {
        let itemClass: CFTypeRef
        switch item.itemClass {
        case "certificate":
            itemClass = kSecClassCertificate
        case "key":
            itemClass = kSecClassKey
        default:
            return errSecParam
        }
        var query: [String: Any] = [kSecClass as String: itemClass]
        applyDataProtectionKeychain(to: &query)
        applyPersistentReference(item.persistentReference, to: &query)
        return SecItemDelete(query as CFDictionary)
    }

    private func applyPersistentReference(
        _ persistentReference: Data,
        to query: inout [String: Any]
    ) {
        #if os(macOS)
        query[kSecMatchItemList as String] = [persistentReference]
        #else
        query[kSecValuePersistentRef as String] = persistentReference
        #endif
    }

    private func applyTransientReferenceMatch(
        _ reference: CFTypeRef,
        to query: inout [String: Any]
    ) {
        #if os(macOS)
        query[kSecMatchItemList as String] = [reference]
        #else
        query[kSecValueRef as String] = reference
        #endif
    }

    private func applyDataProtectionKeychain(
        _ enabled: Bool = true,
        to query: inout [String: Any]
    ) {
        #if os(macOS)
        query[kSecUseDataProtectionKeychain as String] = enabled
        #else
        _ = enabled
        #endif
    }
}
