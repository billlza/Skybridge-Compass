import CryptoKit
import Foundation

/// Selects whether a key-pair operation participates in the active backend
/// contract or only prepares material for an explicit future migration.
enum PQCKeyPairStoreAuthority: Sendable, Equatable {
    case active
    case staged
}

/// A separate authority domain keeps production backend selection global while
/// allowing isolated tests to exercise the add-only claim protocol.
struct PQCBackendAuthorityDomain: Hashable, Sendable {
    static let quantumAdapter = PQCBackendAuthorityDomain(rawValue: "quantum-adapter")
    static let protocolIdentity = PQCBackendAuthorityDomain(rawValue: "protocol-identity")
    static let xWingHPKE = PQCBackendAuthorityDomain(rawValue: "xwing-hpke")

    let rawValue: String

    static func testing(_ identifier: String) -> PQCBackendAuthorityDomain {
        PQCBackendAuthorityDomain(rawValue: "testing.\(identifier)")
    }
}

struct PQCBackendEvidence: OptionSet, Sendable, Equatable {
    let rawValue: UInt8

    static let appleCryptoKit = PQCBackendEvidence(rawValue: 1 << 0)
    static let liboqs = PQCBackendEvidence(rawValue: 1 << 1)
}

enum PQCBackendAuthorityError: Error, LocalizedError, Sendable, Equatable {
    case invalidDomain
    case corruptClaim
    case conflictingBackend(
        existing: PQCKeyPairStoreBackend,
        requested: PQCKeyPairStoreBackend
    )
    case ambiguousExistingBackendEvidence
    case incompleteLegacyKeyMaterial
    case invalidCanonicalKeyContract(
        algorithm: String,
        expectedPublicKeyLength: Int,
        actualPublicKeyLength: Int,
        expectedPrivateKeyLength: Int,
        actualPrivateKeyLength: Int
    )
    case backendUnavailable(PQCKeyPairStoreBackend)
    case noBackendAvailable

    var errorDescription: String? {
        switch self {
        case .invalidDomain:
            return "PQC backend authority domain is empty"
        case .corruptClaim:
            return "PQC backend authority claim is corrupt"
        case let .conflictingBackend(existing, requested):
            return "PQC backend is already fixed to \(existing.rawValue); \(requested.rawValue) requires explicit migration"
        case .ambiguousExistingBackendEvidence:
            return "Both Apple CryptoKit and liboqs key material exist without an authoritative backend claim"
        case .incompleteLegacyKeyMaterial:
            return "Legacy PQC key material is incomplete; backend selection is refused"
        case let .invalidCanonicalKeyContract(
            algorithm,
            expectedPublicKeyLength,
            actualPublicKeyLength,
            expectedPrivateKeyLength,
            actualPrivateKeyLength
        ):
            return "Canonical \(algorithm) key lengths are invalid: expected public/private \(expectedPublicKeyLength)/\(expectedPrivateKeyLength), got \(actualPublicKeyLength)/\(actualPrivateKeyLength)"
        case .backendUnavailable(let backend):
            return "The authoritative PQC backend is unavailable: \(backend.rawValue)"
        case .noBackendAvailable:
            return "No supported PQC backend is available"
        }
    }
}

/// Add-only Keychain authority for the active ML-KEM/ML-DSA backend.
///
/// The generic-password item is the cross-process compare-and-set boundary.
/// No update API is exposed: changing a backend remains an explicit migration
/// operation with its own trust and peer re-pinning policy.
enum PQCBackendAuthorityStore {
    private static let service = "com.skybridge.compass.pqc-backend-authority.v1"
    private static let encodingPrefix = Data("SBPQCBA1".utf8)

    static func load(
        domain: PQCBackendAuthorityDomain = .quantumAdapter,
        scopeSource: SkyBridgeSharedIdentityScopeSource = .requiredEntitlement
    ) throws -> PQCKeyPairStoreBackend? {
        let keychainScope = try scopeSource.resolve()
        return try load(domain: domain, keychainScope: keychainScope)
    }

    private static func load(
        domain: PQCBackendAuthorityDomain,
        keychainScope: KeychainGenericPasswordScope
    ) throws -> PQCKeyPairStoreBackend? {
        let account = try account(for: domain)
        let authoritativeScope = try keychainScope.authoritativeOnly()
        guard let encoded = try KeychainManager.shared.exportKeyStrict(
            service: service,
            account: account,
            scope: authoritativeScope,
            includeLegacyKeychain: false
        ) else {
            return nil
        }
        return try decode(encoded)
    }

    @discardableResult
    static func claim(
        _ backend: PQCKeyPairStoreBackend,
        domain: PQCBackendAuthorityDomain = .quantumAdapter,
        scopeSource: SkyBridgeSharedIdentityScopeSource = .requiredEntitlement
    ) throws -> PQCKeyPairStoreBackend {
        let keychainScope = try scopeSource.resolve()
        return try claim(
            backend,
            domain: domain,
            keychainScope: keychainScope
        )
    }

    @discardableResult
    static func claim(
        _ backend: PQCKeyPairStoreBackend,
        domain: PQCBackendAuthorityDomain,
        keychainScope: KeychainGenericPasswordScope
    ) throws -> PQCKeyPairStoreBackend {
        let account = try account(for: domain)
        let authoritativeScope = try keychainScope.authoritativeOnly()
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: encode(backend),
            service: service,
            account: account,
            scope: authoritativeScope
        )
        guard let winner = try load(
            domain: domain,
            keychainScope: authoritativeScope
        ) else {
            throw PQCBackendAuthorityError.corruptClaim
        }
        guard winner == backend else {
            throw PQCBackendAuthorityError.conflictingBackend(
                existing: winner,
                requested: backend
            )
        }
        return winner
    }

    static func resolveActiveBackend(
        preferred: PQCKeyPairStoreBackend,
        appleAvailable: Bool,
        liboqsAvailable: Bool,
        domain: PQCBackendAuthorityDomain = .quantumAdapter,
        evidence suppliedEvidence: PQCBackendEvidence? = nil,
        scopeSource: SkyBridgeSharedIdentityScopeSource = .requiredEntitlement
    ) throws -> PQCKeyPairStoreBackend {
        let keychainScope = try scopeSource.resolve()
        let selected = try previewActiveBackend(
            preferred: preferred,
            appleAvailable: appleAvailable,
            liboqsAvailable: liboqsAvailable,
            domain: domain,
            evidence: suppliedEvidence,
            keychainScope: keychainScope
        )
        let winner = try claim(
            selected,
            domain: domain,
            keychainScope: keychainScope
        )
        try requireAvailable(
            winner,
            appleAvailable: appleAvailable,
            liboqsAvailable: liboqsAvailable
        )
        return winner
    }

    /// Resolves the backend without writing a claim. Capability reporting and
    /// diagnostics use this path so observation never mutates identity state.
    static func previewActiveBackend(
        preferred: PQCKeyPairStoreBackend,
        appleAvailable: Bool,
        liboqsAvailable: Bool,
        domain: PQCBackendAuthorityDomain = .quantumAdapter,
        evidence suppliedEvidence: PQCBackendEvidence? = nil,
        scopeSource: SkyBridgeSharedIdentityScopeSource = .requiredEntitlement
    ) throws -> PQCKeyPairStoreBackend {
        let keychainScope = try scopeSource.resolve()
        return try previewActiveBackend(
            preferred: preferred,
            appleAvailable: appleAvailable,
            liboqsAvailable: liboqsAvailable,
            domain: domain,
            evidence: suppliedEvidence,
            keychainScope: keychainScope
        )
    }

    private static func previewActiveBackend(
        preferred: PQCKeyPairStoreBackend,
        appleAvailable: Bool,
        liboqsAvailable: Bool,
        domain: PQCBackendAuthorityDomain,
        evidence suppliedEvidence: PQCBackendEvidence?,
        keychainScope: KeychainGenericPasswordScope
    ) throws -> PQCKeyPairStoreBackend {
        if let claimed = try load(
            domain: domain,
            keychainScope: keychainScope
        ) {
            try requireAvailable(
                claimed,
                appleAvailable: appleAvailable,
                liboqsAvailable: liboqsAvailable
            )
            return claimed
        }

        let evidence: PQCBackendEvidence
        if let suppliedEvidence {
            evidence = suppliedEvidence
        } else {
            evidence = try installedKeyMaterialEvidence(
                keychainScope: keychainScope
            )
        }
        let selected: PQCKeyPairStoreBackend
        switch evidence {
        case [.appleCryptoKit, .liboqs]:
            throw PQCBackendAuthorityError.ambiguousExistingBackendEvidence
        case [.appleCryptoKit]:
            selected = .appleCryptoKit
        case [.liboqs]:
            selected = .liboqs
        case []:
            if isAvailable(
                preferred,
                appleAvailable: appleAvailable,
                liboqsAvailable: liboqsAvailable
            ) {
                selected = preferred
            } else if appleAvailable {
                selected = .appleCryptoKit
            } else if liboqsAvailable {
                selected = .liboqs
            } else {
                throw PQCBackendAuthorityError.noBackendAvailable
            }
        default:
            throw PQCBackendAuthorityError.ambiguousExistingBackendEvidence
        }

        try requireAvailable(
            selected,
            appleAvailable: appleAvailable,
            liboqsAvailable: liboqsAvailable
        )
        return selected
    }

    static func installedKeyMaterialEvidence(
        scopeSource: SkyBridgeSharedIdentityScopeSource = .requiredEntitlement
    ) throws -> PQCBackendEvidence {
        let keychainScope = try scopeSource.resolve()
        return try installedKeyMaterialEvidence(keychainScope: keychainScope)
    }

    private static func installedKeyMaterialEvidence(
        keychainScope: KeychainGenericPasswordScope
    ) throws -> PQCBackendEvidence {
        var evidence: PQCBackendEvidence = []
        if try hasCanonicalMaterial(
            for: .appleCryptoKit,
            keychainScope: keychainScope
        ) {
            evidence.insert(.appleCryptoKit)
        }
        if try hasCanonicalMaterial(
            for: .liboqs,
            keychainScope: keychainScope
        ) {
            evidence.insert(.liboqs)
        }
        try mergeLegacyEvidence(
            into: &evidence,
            keychainScope: keychainScope
        )
        return evidence
    }

    static func deleteForTesting(
        domain: PQCBackendAuthorityDomain = .quantumAdapter,
        scopeSource: SkyBridgeSharedIdentityScopeSource = .requiredEntitlement
    ) throws {
        let keychainScope = try scopeSource.resolve()
        let authoritativeScope = try keychainScope.authoritativeOnly()
        try KeychainManager.shared.deleteAPIKey(
            service: service,
            account: account(for: domain),
            scope: authoritativeScope,
            includeLegacyKeychain: false
        )
    }

    #if DEBUG || SKYBRIDGE_TESTING
    @discardableResult
    static func insertUnscopedClaimForTesting(
        _ backend: PQCKeyPairStoreBackend,
        domain: PQCBackendAuthorityDomain
    ) throws -> KeychainInsertResult {
        try KeychainManager.shared.insertKeyIfAbsent(
            data: encode(backend),
            service: service,
            account: account(for: domain),
            scope: .unscopedDataProtectionForTesting
        )
    }

    static func loadUnscopedClaimForTesting(
        domain: PQCBackendAuthorityDomain
    ) throws -> PQCKeyPairStoreBackend? {
        guard let encoded = try KeychainManager.shared.exportKeyStrict(
            service: service,
            account: account(for: domain),
            scope: .unscopedDataProtectionForTesting,
            includeLegacyKeychain: false
        ) else {
            return nil
        }
        return try decode(encoded)
    }

    static func deleteUnscopedClaimForTesting(
        domain: PQCBackendAuthorityDomain
    ) throws {
        try KeychainManager.shared.deleteAPIKey(
            service: service,
            account: account(for: domain),
            scope: .unscopedDataProtectionForTesting,
            includeLegacyKeychain: false
        )
    }
    #endif

    private static func hasCanonicalMaterial(
        for backend: PQCKeyPairStoreBackend,
        keychainScope: KeychainGenericPasswordScope
    ) throws -> Bool {
        for purpose in [PQCKeyPairStorePurpose.signature, .kem] {
            let expectedContracts = canonicalContracts(
                backend: backend,
                purpose: purpose
            )
            let records = try PQCKeyPairStore.canonicalRecordMetadata(
                backend: backend,
                purpose: purpose,
                keychainScope: keychainScope
            )
            for record in records {
                guard let expected = expectedContracts[record.algorithmIdentifier] else {
                    continue
                }
                guard record.publicKeyLength == expected.publicKeyLength,
                      record.privateKeyLength == expected.privateKeyLength else {
                    throw PQCBackendAuthorityError.invalidCanonicalKeyContract(
                        algorithm: record.algorithmIdentifier,
                        expectedPublicKeyLength: expected.publicKeyLength,
                        actualPublicKeyLength: record.publicKeyLength,
                        expectedPrivateKeyLength: expected.privateKeyLength,
                        actualPrivateKeyLength: record.privateKeyLength
                    )
                }
                return true
            }
        }
        return false
    }

    private static func canonicalContracts(
        backend: PQCKeyPairStoreBackend,
        purpose: PQCKeyPairStorePurpose
    ) -> [String: (publicKeyLength: Int, privateKeyLength: Int)] {
        switch (backend, purpose) {
        case (.appleCryptoKit, .signature):
            return [
                "apple-cryptokit/signature/ML-DSA-65": (1_952, 64),
                "apple-cryptokit/signature/ML-DSA-87": (2_592, 64),
            ]
        case (.appleCryptoKit, .kem):
            return [
                "apple-cryptokit/kem/ML-KEM-768": (1_184, 96),
                "apple-cryptokit/kem/ML-KEM-1024": (1_568, 96),
            ]
        case (.liboqs, .signature):
            return [
                "liboqs/signature/ML-DSA-65": (1_952, 4_032),
                "liboqs/signature/ML-DSA-87": (2_592, 4_896),
            ]
        case (.liboqs, .kem):
            return [
                "liboqs/kem/ML-KEM-768": (1_184, 2_400),
                "liboqs/kem/ML-KEM-1024": (1_568, 3_168),
            ]
        }
    }

    private static func mergeLegacyEvidence(
        into evidence: inout PQCBackendEvidence,
        keychainScope: KeychainGenericPasswordScope
    ) throws {
        let algorithms = [
            ("MLDSA", "65"),
            ("MLDSA", "87"),
            ("MLKEM", "768"),
            ("MLKEM", "1024"),
        ]
        for (algorithm, variant) in algorithms {
            let publicSlots = try legacyEvidenceSlots(
                service: PQCKeyTags.service(algorithm, variant, "Pub"),
                keychainScope: keychainScope
            )
            let applePrivateSlots = try legacyEvidenceSlots(
                service: PQCKeyTags.service(algorithm, variant, "Mem"),
                keychainScope: keychainScope
            )
            let oqsPrivateSlots = try legacyEvidenceSlots(
                service: PQCKeyTags.service(algorithm, variant, "Priv"),
                keychainScope: keychainScope
            )

            let privateSlots = applePrivateSlots.union(oqsPrivateSlots)
            guard applePrivateSlots.isSubset(of: publicSlots),
                  oqsPrivateSlots.isSubset(of: publicSlots),
                  publicSlots.isSubset(of: privateSlots) else {
                throw PQCBackendAuthorityError.incompleteLegacyKeyMaterial
            }
            if !applePrivateSlots.isEmpty {
                evidence.insert(.appleCryptoKit)
            }
            if !oqsPrivateSlots.isEmpty {
                evidence.insert(.liboqs)
            }
        }
    }

    private struct LegacyEvidenceSlot: Hashable {
        let account: String
        let actualAccessGroup: String?
        let usesDataProtectionKeychain: Bool
    }

    private static func legacyEvidenceSlots(
        service: String,
        keychainScope: KeychainGenericPasswordScope
    ) throws -> Set<LegacyEvidenceSlot> {
        var accounts = try KeychainManager.shared.genericPasswordAccountsStrict(
            service: service,
            scope: keychainScope,
            includeLegacyKeychain: true
        )
        accounts.formUnion(
            try KeychainManager.shared.genericPasswordAccountsStrict(
                service: service
            )
        )
        var slots = Set<LegacyEvidenceSlot>()
        for account in accounts {
            let candidates = try KeychainManager.shared
                .legacyGenericPasswordMetadataCandidatesStrict(
                    service: service,
                    account: account,
                    includeLegacyKeychain: true
                )
            for candidate in candidates {
                slots.insert(
                    LegacyEvidenceSlot(
                        account: account,
                        actualAccessGroup: candidate.location.actualAccessGroup,
                        usesDataProtectionKeychain: candidate.location
                            .usesDataProtectionKeychain
                    )
                )
            }
        }
        return slots
    }

    private static func account(for domain: PQCBackendAuthorityDomain) throws -> String {
        let normalized = domain.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw PQCBackendAuthorityError.invalidDomain
        }
        return SHA256.hash(data: Data(normalized.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func encode(_ backend: PQCKeyPairStoreBackend) -> Data {
        var encoded = encodingPrefix
        encoded.append(backend == .appleCryptoKit ? 1 : 2)
        return encoded
    }

    private static func decode(_ encoded: Data) throws -> PQCKeyPairStoreBackend {
        guard encoded.count == encodingPrefix.count + 1,
              encoded.prefix(encodingPrefix.count) == encodingPrefix else {
            throw PQCBackendAuthorityError.corruptClaim
        }
        switch encoded[encoded.startIndex + encodingPrefix.count] {
        case 1:
            return .appleCryptoKit
        case 2:
            return .liboqs
        default:
            throw PQCBackendAuthorityError.corruptClaim
        }
    }

    private static func requireAvailable(
        _ backend: PQCKeyPairStoreBackend,
        appleAvailable: Bool,
        liboqsAvailable: Bool
    ) throws {
        guard isAvailable(
            backend,
            appleAvailable: appleAvailable,
            liboqsAvailable: liboqsAvailable
        ) else {
            throw PQCBackendAuthorityError.backendUnavailable(backend)
        }
    }

    private static func isAvailable(
        _ backend: PQCKeyPairStoreBackend,
        appleAvailable: Bool,
        liboqsAvailable: Bool
    ) -> Bool {
        switch backend {
        case .appleCryptoKit:
            return appleAvailable
        case .liboqs:
            return liboqsAvailable
        }
    }
}
