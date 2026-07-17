import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, *)
final class PQCBackendAuthorityTests: XCTestCase {
    private struct StorageContext: Sendable {
        let domain: PQCBackendAuthorityDomain
        let keychainScope: KeychainGenericPasswordScope

        var scopeSource: SkyBridgeSharedIdentityScopeSource {
            .explicitForTesting(keychainScope)
        }

        var keyPairStorageScope: PQCKeyPairStoreStorageScope {
            PQCKeyPairStoreStorageScope(
                canonicalLocation: nil,
                keychainScope: keychainScope,
                includeLegacyKeychain: true
            )
        }
    }

    private enum ClaimOutcome: Sendable {
        case selected(PQCKeyPairStoreBackend)
        case conflict(
            existing: PQCKeyPairStoreBackend,
            requested: PQCKeyPairStoreBackend
        )
        case unexpected(String)
    }

    private struct LegacyMigrationFixture {
        let descriptor: PQCKeyPairStoreDescriptor
        let storage: PQCKeyPairStoreLegacyKeyPair
        let publicLocation: KeychainGenericPasswordLocation
        let privateLocation: KeychainGenericPasswordLocation
    }

    #if DEBUG || SKYBRIDGE_TESTING
    private enum InjectedReconciliationError: Error {
        case interruption
    }
    #endif

    func testSameDomainClaimsRemainIsolatedByConcreteScope() throws {
        let domain = PQCBackendAuthorityDomain.testing(UUID().uuidString)
        let first = isolatedContext(domain: domain)
        let second = isolatedContext(domain: domain)
        defer {
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: first.scopeSource
            )
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: second.scopeSource
            )
        }

        XCTAssertEqual(
            try PQCBackendAuthorityStore.claim(
                .liboqs,
                domain: domain,
                scopeSource: first.scopeSource
            ),
            .liboqs
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.claim(
                .appleCryptoKit,
                domain: domain,
                scopeSource: second.scopeSource
            ),
            .appleCryptoKit
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: first.scopeSource
            ),
            .liboqs
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: second.scopeSource
            ),
            .appleCryptoKit
        )
    }

    #if DEBUG || SKYBRIDGE_TESTING
    func testUnscopedAuthorityClaimIsIgnoredAndNeverDeletedBySharedAuthority() throws {
        let domain = PQCBackendAuthorityDomain.testing(UUID().uuidString)
        let context = isolatedContext(
            domain: domain,
            includeUnscopedRead: true
        )
        defer {
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: context.scopeSource
            )
            try? PQCBackendAuthorityStore.deleteUnscopedClaimForTesting(
                domain: domain
            )
        }

        XCTAssertEqual(
            try PQCBackendAuthorityStore.insertUnscopedClaimForTesting(
                .appleCryptoKit,
                domain: domain
            ),
            .inserted
        )
        XCTAssertNil(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            ),
            "An app-private legacy item cannot govern a shared app/extension backend"
        )

        XCTAssertEqual(
            try PQCBackendAuthorityStore.claim(
                .liboqs,
                domain: domain,
                scopeSource: context.scopeSource
            ),
            .liboqs
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            ),
            .liboqs
        )

        try PQCBackendAuthorityStore.deleteForTesting(
            domain: domain,
            scopeSource: context.scopeSource
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.loadUnscopedClaimForTesting(domain: domain),
            .appleCryptoKit,
            "Shared-authority cleanup must not mutate unrelated unscoped state"
        )
        XCTAssertNil(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            ),
            "Removing the shared claim must not expose the unscoped item as a fallback"
        )
    }
    #endif

    #if DEBUG || SKYBRIDGE_TESTING
    func testUnscopedCanonicalRecordIsNotActiveBackendEvidence() throws {
        let context = isolatedContext(includeUnscopedRead: true)
        let domain = context.domain
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: "authority-unscoped-canonical-\(UUID().uuidString)",
            authority: .active,
            authorityDomain: domain,
            storageScope: context.keyPairStorageScope
        )
        defer {
            try? PQCKeyPairStore.deleteUnscopedCanonicalRecordForTesting(
                descriptor: descriptor
            )
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: context.scopeSource
            )
        }

        var candidate = appleMLDSA65Record(descriptor: descriptor)
        defer { PQCKeyPairRecordCodec.wipe(&candidate.privateKey) }
        XCTAssertEqual(
            try PQCKeyPairStore.insertUnscopedCanonicalRecordForTesting(
                candidate,
                descriptor: descriptor
            ),
            .inserted
        )

        XCTAssertEqual(
            try PQCBackendAuthorityStore.installedKeyMaterialEvidence(
                scopeSource: context.scopeSource
            ),
            PQCBackendEvidence(rawValue: 0),
            "An unscoped canonical-v3 record requires validated promotion before it can become backend evidence"
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.previewActiveBackend(
                preferred: .liboqs,
                appleAvailable: true,
                liboqsAvailable: true,
                domain: domain,
                scopeSource: context.scopeSource
            ),
            .liboqs
        )
        XCTAssertNil(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            )
        )
    }
    #endif

    func testConcurrentOpposingClaimsConvergeOnOneImmutableWinner() async throws {
        let context = isolatedContext()
        let domain = context.domain
        defer {
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: context.scopeSource
            )
        }

        let outcomes = await withTaskGroup(of: ClaimOutcome.self) { group in
            for index in 0..<32 {
                let requested: PQCKeyPairStoreBackend = index.isMultiple(of: 2)
                    ? .appleCryptoKit
                    : .liboqs
                group.addTask {
                    do {
                        return .selected(
                            try PQCBackendAuthorityStore.claim(
                                requested,
                                domain: domain,
                                scopeSource: context.scopeSource
                            )
                        )
                    } catch let error as PQCBackendAuthorityError {
                        if case let .conflictingBackend(existing, rejected) = error {
                            return .conflict(existing: existing, requested: rejected)
                        }
                        return .unexpected(error.localizedDescription)
                    } catch {
                        return .unexpected(error.localizedDescription)
                    }
                }
            }
            var collected: [ClaimOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        let winner = try XCTUnwrap(
            PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            )
        )
        XCTAssertEqual(outcomes.count, 32)
        for outcome in outcomes {
            switch outcome {
            case .selected(let selected):
                XCTAssertEqual(selected, winner)
            case let .conflict(existing, requested):
                XCTAssertEqual(existing, winner)
                XCTAssertNotEqual(requested, winner)
            case .unexpected(let description):
                XCTFail("Unexpected claim result: \(description)")
            }
        }
    }

    func testUpgradePreviewPreservesExistingOQSIdentityWithoutWritingClaim() throws {
        let context = isolatedContext()
        let domain = context.domain
        defer {
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: context.scopeSource
            )
        }

        let preview = try PQCBackendAuthorityStore.previewActiveBackend(
            preferred: .appleCryptoKit,
            appleAvailable: true,
            liboqsAvailable: true,
            domain: domain,
            evidence: .liboqs,
            scopeSource: context.scopeSource
        )
        XCTAssertEqual(preview, .liboqs)
        XCTAssertNil(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            ),
            "Capability preview must not persist backend authority"
        )

        let activated = try PQCBackendAuthorityStore.resolveActiveBackend(
            preferred: .appleCryptoKit,
            appleAvailable: true,
            liboqsAvailable: true,
            domain: domain,
            evidence: .liboqs,
            scopeSource: context.scopeSource
        )
        XCTAssertEqual(activated, .liboqs)
        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            ),
            .liboqs
        )
    }

    func testBothBackendsWithoutClaimFailClosedAndDoNotElectEither() throws {
        let context = isolatedContext()
        let domain = context.domain
        defer {
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: context.scopeSource
            )
        }

        XCTAssertThrowsError(
            try PQCBackendAuthorityStore.resolveActiveBackend(
                preferred: .appleCryptoKit,
                appleAvailable: true,
                liboqsAvailable: true,
                domain: domain,
                evidence: [.appleCryptoKit, .liboqs],
                scopeSource: context.scopeSource
            )
        ) { error in
            XCTAssertEqual(
                error as? PQCBackendAuthorityError,
                .ambiguousExistingBackendEvidence
            )
        }
        XCTAssertNil(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            )
        )
    }

    func testLegacyProbeRequiresCompletePairBeforePreservingOQSBackend() throws {
        let account = "authority-incomplete-\(UUID().uuidString)"
        let publicService = PQCKeyTags.service("MLDSA", "65", "Pub")
        let privateService = PQCKeyTags.service("MLDSA", "65", "Priv")
        let accessGroup = "group.com.skybridge.tests.authority.\(UUID().uuidString)"
        let scope = KeychainGenericPasswordScope(
            accessibility: .afterFirstUnlockThisDeviceOnly,
            writeAccessGroup: accessGroup,
            readAccessGroups: [accessGroup],
            usesDataProtectionKeychain: true,
            synchronizable: false
        )
        let scopeSource = SkyBridgeSharedIdentityScopeSource.explicitForTesting(scope)
        defer {
            try? KeychainManager.shared.deleteAPIKey(
                service: publicService,
                account: account,
                scope: scope
            )
            try? KeychainManager.shared.deleteAPIKey(
                service: privateService,
                account: account,
                scope: scope
            )
        }
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: Data([0xA5]),
            service: privateService,
            account: account,
            scope: scope
        )

        XCTAssertThrowsError(
            try PQCBackendAuthorityStore.installedKeyMaterialEvidence(
                scopeSource: scopeSource
            )
        ) { error in
            XCTAssertEqual(
                error as? PQCBackendAuthorityError,
                .incompleteLegacyKeyMaterial
            )
        }

        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: Data([0x5A]),
            service: publicService,
            account: account,
            scope: scope
        )
        XCTAssertTrue(
            try PQCBackendAuthorityStore.installedKeyMaterialEvidence(
                scopeSource: scopeSource
            )
                .contains(.liboqs),
            "A complete historical Pub/Priv identity must preserve liboqs across an OS upgrade"
        )
    }

    func testLegacyEvidenceDoesNotJoinPairAcrossKeychainNamespaces() throws {
        let context = isolatedContext(includeUnscopedRead: true)
        let account = "authority-cross-namespace-\(UUID().uuidString)"
        let publicService = PQCKeyTags.service("MLDSA", "65", "Pub")
        let privateService = PQCKeyTags.service("MLDSA", "65", "Priv")
        defer {
            try? KeychainManager.shared.deleteAPIKey(
                service: publicService,
                account: account,
                scope: context.keychainScope
            )
            try? KeychainManager.shared.deleteAPIKey(
                service: privateService,
                account: account,
                scope: .unscopedDataProtectionForTesting,
                includeLegacyKeychain: false
            )
        }
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: Data([0xA1]),
            service: publicService,
            account: account,
            scope: context.keychainScope
        )
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: Data([0xB2]),
            service: privateService,
            account: account,
            scope: .unscopedDataProtectionForTesting
        )

        XCTAssertThrowsError(
            try PQCBackendAuthorityStore.installedKeyMaterialEvidence(
                scopeSource: context.scopeSource
            )
        ) { error in
            XCTAssertEqual(
                error as? PQCBackendAuthorityError,
                .incompleteLegacyKeyMaterial
            )
        }
    }

    func testCanonicalConflictWithLegacyPairRemainsVisibleOnRetry() throws {
        let context = isolatedContext()
        let identity = "persistent-legacy-conflict-\(UUID().uuidString)"
        let publicLocation = KeychainGenericPasswordLocation(
            service: "com.skybridge.tests.pqc-legacy-public.\(UUID().uuidString)",
            account: identity
        )
        let privateLocation = KeychainGenericPasswordLocation(
            service: "com.skybridge.tests.pqc-legacy-private.\(UUID().uuidString)",
            account: identity
        )
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "TEST-PQC",
            identity: identity,
            authority: .staged,
            authorityDomain: context.domain,
            storageScope: context.keyPairStorageScope
        )
        let legacyStorage = PQCKeyPairStoreLegacyKeyPair(
            publicKeyLocation: publicLocation,
            privateKeyLocation: privateLocation,
            keychainScopeSource: context.scopeSource,
            includeLegacyKeychain: true
        )
        defer {
            try? PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            try? KeychainManager.shared.deleteAPIKey(
                service: publicLocation.service,
                account: publicLocation.account,
                scope: context.keychainScope
            )
            try? KeychainManager.shared.deleteAPIKey(
                service: privateLocation.service,
                account: privateLocation.account,
                scope: context.keychainScope
            )
        }
        let canonical = PQCKeyPairRecord(
            algorithmIdentifier: descriptor.algorithmIdentifier,
            publicKey: Data([0x01, 0x02]),
            privateKey: Data([0x03, 0x04])
        )
        _ = try PQCKeyPairStore.insertIfAbsent(
            canonical,
            descriptor: descriptor,
            publicKeyLength: 2,
            privateKeyLength: 2,
            validatePair: { _ in }
        )
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: Data([0x11, 0x12]),
            service: publicLocation.service,
            account: publicLocation.account,
            scope: context.keychainScope
        )
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: Data([0x13, 0x14]),
            service: privateLocation.service,
            account: privateLocation.account,
            scope: context.keychainScope
        )

        for _ in 0..<2 {
            XCTAssertThrowsError(
                try PQCKeyPairStore.loadOrMigrateLegacy(
                    descriptor: descriptor,
                    publicKeyLength: 2,
                    privateKeyLength: 2,
                    legacyKeyPair: legacyStorage,
                    validatePair: { _ in }
                )
            ) { error in
                guard let storeError = error as? PQCKeyPairStoreError,
                      case .conflictingLegacyKeyPair(let algorithm) = storeError else {
                    return XCTFail("Unexpected durable conflict: \(error)")
                }
                XCTAssertEqual(algorithm, "TEST-PQC")
            }
            XCTAssertEqual(
                try KeychainManager.shared
                    .legacyGenericPasswordCandidatesStrict(
                        service: publicLocation.service,
                        account: publicLocation.account
                    ).count,
                1
            )
            XCTAssertEqual(
                try KeychainManager.shared
                    .legacyGenericPasswordCandidatesStrict(
                        service: privateLocation.service,
                        account: privateLocation.account
                    ).count,
                1
            )
        }
    }

    func testMatchingLegacyPairIsCleanedAndRetryUsesCanonicalOnly() throws {
        let context = isolatedContext()
        let identity = "matching-legacy-cleanup-\(UUID().uuidString)"
        let publicLocation = KeychainGenericPasswordLocation(
            service: "com.skybridge.tests.pqc-matching-public.\(UUID().uuidString)",
            account: identity
        )
        let privateLocation = KeychainGenericPasswordLocation(
            service: "com.skybridge.tests.pqc-matching-private.\(UUID().uuidString)",
            account: identity
        )
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .kem,
            algorithm: "TEST-KEM",
            identity: identity,
            authority: .staged,
            authorityDomain: context.domain,
            storageScope: context.keyPairStorageScope
        )
        let legacyStorage = PQCKeyPairStoreLegacyKeyPair(
            publicKeyLocation: publicLocation,
            privateKeyLocation: privateLocation,
            keychainScopeSource: context.scopeSource,
            includeLegacyKeychain: true
        )
        defer {
            try? PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            try? KeychainManager.shared.deleteAPIKey(
                service: publicLocation.service,
                account: publicLocation.account,
                scope: context.keychainScope
            )
            try? KeychainManager.shared.deleteAPIKey(
                service: privateLocation.service,
                account: privateLocation.account,
                scope: context.keychainScope
            )
        }
        let record = PQCKeyPairRecord(
            algorithmIdentifier: descriptor.algorithmIdentifier,
            publicKey: Data([0x21, 0x22]),
            privateKey: Data([0x23, 0x24])
        )
        _ = try PQCKeyPairStore.insertIfAbsent(
            record,
            descriptor: descriptor,
            publicKeyLength: 2,
            privateKeyLength: 2,
            validatePair: { _ in }
        )
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: record.publicKey,
            service: publicLocation.service,
            account: publicLocation.account,
            scope: context.keychainScope
        )
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: record.privateKey,
            service: privateLocation.service,
            account: privateLocation.account,
            scope: context.keychainScope
        )

        for _ in 0..<2 {
            var loaded = try XCTUnwrap(
                PQCKeyPairStore.loadOrMigrateLegacy(
                    descriptor: descriptor,
                    publicKeyLength: 2,
                    privateKeyLength: 2,
                    legacyKeyPair: legacyStorage,
                    validatePair: { _ in }
                )
            )
            XCTAssertEqual(loaded, record)
            PQCKeyPairRecordCodec.wipe(&loaded.privateKey)
        }
        XCTAssertTrue(
            try KeychainManager.shared
                .legacyGenericPasswordCandidatesStrict(
                    service: publicLocation.service,
                    account: publicLocation.account
                ).isEmpty
        )
        XCTAssertTrue(
            try KeychainManager.shared
                .legacyGenericPasswordCandidatesStrict(
                    service: privateLocation.service,
                    account: privateLocation.account
                ).isEmpty
        )
    }

    #if DEBUG || SKYBRIDGE_TESTING
    func testConcurrentCanonicalWinnerAfterStrictMissIsNeverDeletedAsLegacy() throws {
        let context = isolatedContext()
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .signature,
            algorithm: "TEST-RACE",
            identity: "canonical-miss-race-\(UUID().uuidString)",
            authority: .staged,
            authorityDomain: context.domain,
            storageScope: context.keyPairStorageScope
        )
        defer {
            try? PQCKeyPairStore.clearReconciliationHooksForTesting(
                descriptor: descriptor
            )
            try? PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
        }

        try PQCKeyPairStore.installCanonicalMissHookForTesting(
            descriptor: descriptor
        ) {
            let competingRecord = PQCKeyPairRecord(
                algorithmIdentifier: descriptor.algorithmIdentifier,
                publicKey: Data([0x31, 0x32]),
                privateKey: Data([0x33, 0x34])
            )
            var persisted = try PQCKeyPairStore.insertIfAbsent(
                competingRecord,
                descriptor: descriptor,
                publicKeyLength: 2,
                privateKeyLength: 2,
                validatePair: { _ in }
            )
            PQCKeyPairRecordCodec.wipe(&persisted.privateKey)
        }

        for _ in 0..<2 {
            var loaded = try XCTUnwrap(
                PQCKeyPairStore.load(
                    descriptor: descriptor,
                    publicKeyLength: 2,
                    privateKeyLength: 2,
                    validatePair: { _ in }
                )
            )
            XCTAssertEqual(loaded.publicKey, Data([0x31, 0x32]))
            XCTAssertEqual(loaded.privateKey, Data([0x33, 0x34]))
            PQCKeyPairRecordCodec.wipe(&loaded.privateKey)
        }
    }
    #endif

    func testMissingCanonicalAndLegacyReturnsNilAfterSingleScan() throws {
        let context = isolatedContext()
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .liboqs,
            purpose: .kem,
            algorithm: "TEST-MISSING",
            identity: "canonical-missing-\(UUID().uuidString)",
            authority: .staged,
            authorityDomain: context.domain,
            storageScope: context.keyPairStorageScope
        )
        defer { try? PQCKeyPairStore.deleteForTesting(descriptor: descriptor) }

        XCTAssertNil(
            try PQCKeyPairStore.load(
                descriptor: descriptor,
                publicKeyLength: 2,
                privateKeyLength: 2,
                validatePair: { _ in }
            )
        )
    }

    func testLegacyFileKeychainSearchRequiresExplicitOptIn() throws {
        let context = isolatedContext()
        let identity = "legacy-file-scope-\(UUID().uuidString)"
        let publicLocation = KeychainGenericPasswordLocation(
            service: "com.skybridge.tests.pqc-file-public.\(UUID().uuidString)",
            account: identity
        )
        let privateLocation = KeychainGenericPasswordLocation(
            service: "com.skybridge.tests.pqc-file-private.\(UUID().uuidString)",
            account: identity
        )
        let record = PQCKeyPairRecord(
            algorithmIdentifier: "liboqs/kem/TEST-FILE-SCOPE",
            publicKey: Data([0x91, 0x92]),
            privateKey: Data([0x93, 0x94])
        )

        func descriptor(includeLegacyKeychain: Bool) -> PQCKeyPairStoreDescriptor {
            PQCKeyPairStoreDescriptor(
                backend: .liboqs,
                purpose: .kem,
                algorithm: "TEST-FILE-SCOPE",
                identity: identity,
                authority: .staged,
                authorityDomain: context.domain,
                storageScope: PQCKeyPairStoreStorageScope(
                    canonicalLocation: nil,
                    keychainScope: context.keychainScope,
                    includeLegacyKeychain: includeLegacyKeychain
                )
            )
        }

        func legacyStorage(
            includeLegacyKeychain: Bool
        ) -> PQCKeyPairStoreLegacyKeyPair {
            PQCKeyPairStoreLegacyKeyPair(
                publicKeyLocation: publicLocation,
                privateKeyLocation: privateLocation,
                keychainScopeSource: context.scopeSource,
                includeLegacyKeychain: includeLegacyKeychain
            )
        }

        let legacyDisabled = descriptor(includeLegacyKeychain: false)
        let legacyEnabled = descriptor(includeLegacyKeychain: true)
        defer {
            try? PQCKeyPairStore.deleteForTesting(descriptor: legacyEnabled)
            try? KeychainManager.shared.deleteAPIKey(
                service: publicLocation.service,
                account: publicLocation.account,
                scope: .applicationDefault,
                includeLegacyKeychain: false
            )
            try? KeychainManager.shared.deleteAPIKey(
                service: privateLocation.service,
                account: privateLocation.account,
                scope: .applicationDefault,
                includeLegacyKeychain: false
            )
        }

        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: record.publicKey,
            service: publicLocation.service,
            account: publicLocation.account,
            scope: .applicationDefault
        )
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: record.privateKey,
            service: privateLocation.service,
            account: privateLocation.account,
            scope: .applicationDefault
        )

        XCTAssertNil(
            try PQCKeyPairStore.loadOrMigrateLegacy(
                descriptor: legacyDisabled,
                publicKeyLength: 2,
                privateKeyLength: 2,
                legacyKeyPair: legacyStorage(includeLegacyKeychain: false),
                validatePair: { _ in }
            )
        )
        XCTAssertEqual(
            try KeychainManager.shared.exportKeyStrict(
                service: publicLocation.service,
                account: publicLocation.account,
                scope: .applicationDefault,
                includeLegacyKeychain: false
            ),
            record.publicKey,
            "A disabled legacy-file search must not mutate the excluded item"
        )
        XCTAssertEqual(
            try KeychainManager.shared.exportKeyStrict(
                service: privateLocation.service,
                account: privateLocation.account,
                scope: .applicationDefault,
                includeLegacyKeychain: false
            ),
            record.privateKey
        )

        var migrated = try XCTUnwrap(
            PQCKeyPairStore.loadOrMigrateLegacy(
                descriptor: legacyEnabled,
                publicKeyLength: 2,
                privateKeyLength: 2,
                legacyKeyPair: legacyStorage(includeLegacyKeychain: true),
                validatePair: { _ in }
            )
        )
        XCTAssertEqual(migrated, record)
        PQCKeyPairRecordCodec.wipe(&migrated.privateKey)
        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: publicLocation.service,
                account: publicLocation.account,
                scope: .applicationDefault,
                includeLegacyKeychain: false
            )
        )
        XCTAssertNil(
            try KeychainManager.shared.exportKeyStrict(
                service: privateLocation.service,
                account: privateLocation.account,
                scope: .applicationDefault,
                includeLegacyKeychain: false
            )
        )
    }

    #if DEBUG || SKYBRIDGE_TESTING
    func testInterruptedSplitCleanupRetriesFromRemainingPrivateCandidate() throws {
        let context = isolatedContext()
        let fixture = legacyMigrationFixture(
            context: context,
            algorithm: "TEST-INTERRUPTED-CLEANUP",
            purpose: .signature
        )
        defer {
            try? PQCKeyPairStore.clearReconciliationHooksForTesting(
                descriptor: fixture.descriptor
            )
            cleanupLegacyMigrationFixture(fixture, context: context)
        }
        let record = PQCKeyPairRecord(
            algorithmIdentifier: fixture.descriptor.algorithmIdentifier,
            publicKey: Data([0x41, 0x42]),
            privateKey: Data([0x43, 0x44])
        )
        try seedLegacyRecord(record, fixture: fixture, context: context)
        try PQCKeyPairStore.installSplitDeletionHookForTesting(
            descriptor: fixture.descriptor
        ) {
            throw InjectedReconciliationError.interruption
        }

        XCTAssertThrowsError(
            try PQCKeyPairStore.loadOrMigrateLegacy(
                descriptor: fixture.descriptor,
                publicKeyLength: 2,
                privateKeyLength: 2,
                legacyKeyPair: fixture.storage,
                validatePair: { _ in }
            )
        ) { error in
            guard error is InjectedReconciliationError else {
                return XCTFail("Unexpected injected cleanup error: \(error)")
            }
        }
        XCTAssertEqual(
            try legacyCandidateCount(fixture.publicLocation),
            0,
            "The first exact deletion must remain committed"
        )
        XCTAssertEqual(
            try legacyCandidateCount(fixture.privateLocation),
            1,
            "The interrupted private remnant must remain retryable"
        )

        var recovered = try XCTUnwrap(
            PQCKeyPairStore.loadOrMigrateLegacy(
                descriptor: fixture.descriptor,
                publicKeyLength: 2,
                privateKeyLength: 2,
                legacyKeyPair: fixture.storage,
                validatePair: { _ in }
            )
        )
        XCTAssertEqual(recovered, record)
        PQCKeyPairRecordCodec.wipe(&recovered.privateKey)
        XCTAssertEqual(try legacyCandidateCount(fixture.publicLocation), 0)
        XCTAssertEqual(try legacyCandidateCount(fixture.privateLocation), 0)
    }
    #endif

    func testCanonicalReconciliationCleansEitherMatchingHalfIndependently() throws {
        let context = isolatedContext()
        let fixture = legacyMigrationFixture(
            context: context,
            algorithm: "TEST-HALF-CLEANUP",
            purpose: .kem
        )
        defer { cleanupLegacyMigrationFixture(fixture, context: context) }
        let record = PQCKeyPairRecord(
            algorithmIdentifier: fixture.descriptor.algorithmIdentifier,
            publicKey: Data([0x51, 0x52]),
            privateKey: Data([0x53, 0x54])
        )
        var canonical = try PQCKeyPairStore.insertIfAbsent(
            record,
            descriptor: fixture.descriptor,
            publicKeyLength: 2,
            privateKeyLength: 2,
            validatePair: { _ in }
        )
        PQCKeyPairRecordCodec.wipe(&canonical.privateKey)

        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: record.publicKey,
            service: fixture.publicLocation.service,
            account: fixture.publicLocation.account,
            scope: context.keychainScope
        )
        var publicRecovered = try XCTUnwrap(
            PQCKeyPairStore.loadOrMigrateLegacy(
                descriptor: fixture.descriptor,
                publicKeyLength: 2,
                privateKeyLength: 2,
                legacyKeyPair: fixture.storage,
                validatePair: { _ in }
            )
        )
        PQCKeyPairRecordCodec.wipe(&publicRecovered.privateKey)
        XCTAssertEqual(try legacyCandidateCount(fixture.publicLocation), 0)

        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: record.privateKey,
            service: fixture.privateLocation.service,
            account: fixture.privateLocation.account,
            scope: context.keychainScope
        )
        var privateRecovered = try XCTUnwrap(
            PQCKeyPairStore.loadOrMigrateLegacy(
                descriptor: fixture.descriptor,
                publicKeyLength: 2,
                privateKeyLength: 2,
                legacyKeyPair: fixture.storage,
                validatePair: { _ in }
            )
        )
        PQCKeyPairRecordCodec.wipe(&privateRecovered.privateKey)
        XCTAssertEqual(try legacyCandidateCount(fixture.privateLocation), 0)
    }

    func testConflictingHalfRemainsFailClosedAcrossRetries() throws {
        let context = isolatedContext()
        let fixture = legacyMigrationFixture(
            context: context,
            algorithm: "TEST-HALF-CONFLICT",
            purpose: .signature
        )
        defer { cleanupLegacyMigrationFixture(fixture, context: context) }
        let canonicalRecord = PQCKeyPairRecord(
            algorithmIdentifier: fixture.descriptor.algorithmIdentifier,
            publicKey: Data([0x61, 0x62]),
            privateKey: Data([0x63, 0x64])
        )
        var canonical = try PQCKeyPairStore.insertIfAbsent(
            canonicalRecord,
            descriptor: fixture.descriptor,
            publicKeyLength: 2,
            privateKeyLength: 2,
            validatePair: { _ in }
        )
        PQCKeyPairRecordCodec.wipe(&canonical.privateKey)
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: Data([0xF3, 0xF4]),
            service: fixture.privateLocation.service,
            account: fixture.privateLocation.account,
            scope: context.keychainScope
        )

        for _ in 0..<2 {
            XCTAssertThrowsError(
                try PQCKeyPairStore.loadOrMigrateLegacy(
                    descriptor: fixture.descriptor,
                    publicKeyLength: 2,
                    privateKeyLength: 2,
                    legacyKeyPair: fixture.storage,
                    validatePair: { _ in }
                )
            ) { error in
                guard let storeError = error as? PQCKeyPairStoreError,
                      case .conflictingLegacyKeyPair(let algorithm) = storeError else {
                    return XCTFail("Unexpected half-conflict error: \(error)")
                }
                XCTAssertEqual(algorithm, "TEST-HALF-CONFLICT")
            }
            XCTAssertEqual(try legacyCandidateCount(fixture.privateLocation), 1)
        }
    }

    func testMalformedLegacyPairRemainsTypedConflictAcrossRetries() throws {
        let context = isolatedContext()
        let fixture = legacyMigrationFixture(
            context: context,
            algorithm: "TEST-MALFORMED-LEGACY",
            purpose: .signature
        )
        defer { cleanupLegacyMigrationFixture(fixture, context: context) }
        let malformed = PQCKeyPairRecord(
            algorithmIdentifier: fixture.descriptor.algorithmIdentifier,
            publicKey: Data([0x71, 0x72]),
            privateKey: Data([0x73, 0x74])
        )
        try seedLegacyRecord(malformed, fixture: fixture, context: context)

        for _ in 0..<2 {
            XCTAssertThrowsError(
                try PQCKeyPairStore.loadOrMigrateLegacy(
                    descriptor: fixture.descriptor,
                    publicKeyLength: 2,
                    privateKeyLength: 2,
                    legacyKeyPair: fixture.storage,
                    validatePair: { _ in
                        throw NSError(
                            domain: "PQCBackendAuthorityTests.MalformedLegacy",
                            code: 1
                        )
                    }
                )
            ) { error in
                guard let storeError = error as? PQCKeyPairStoreError,
                      case .conflictingLegacyKeyPair(let algorithm) = storeError else {
                    return XCTFail("Unexpected malformed-legacy error: \(error)")
                }
                XCTAssertEqual(algorithm, "TEST-MALFORMED-LEGACY")
            }
            XCTAssertEqual(try legacyCandidateCount(fixture.publicLocation), 1)
            XCTAssertEqual(try legacyCandidateCount(fixture.privateLocation), 1)
        }
    }

    func testStagedAppleRekeyDoesNotSwitchActiveOQSBackend() throws {
        let context = isolatedContext()
        let domain = context.domain
        let identity = "authority-staged-\(UUID().uuidString)"
        let stagedApple = PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: identity,
            authority: .staged,
            authorityDomain: domain,
            storageScope: context.keyPairStorageScope
        )
        let activeApple = PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: identity,
            authority: .active,
            authorityDomain: domain,
            storageScope: context.keyPairStorageScope
        )
        defer {
            try? PQCKeyPairStore.deleteForTesting(descriptor: stagedApple)
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: context.scopeSource
            )
        }

        try PQCBackendAuthorityStore.claim(
            .liboqs,
            domain: domain,
            scopeSource: context.scopeSource
        )
        let candidate = PQCKeyPairRecord(
            algorithmIdentifier: stagedApple.algorithmIdentifier,
            publicKey: Data([0x11, 0x22]),
            privateKey: Data([0x33, 0x44])
        )
        _ = try PQCKeyPairStore.insertIfAbsent(
            candidate,
            descriptor: stagedApple,
            publicKeyLength: 2,
            privateKeyLength: 2,
            validatePair: { _ in }
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            ),
            .liboqs
        )

        XCTAssertNil(
            try PQCKeyPairStore.load(
                descriptor: activeApple,
                publicKeyLength: 2,
                privateKeyLength: 2,
                validatePair: { _ in }
            ),
            "Staged material must not appear in the active canonical namespace"
        )
        XCTAssertThrowsError(
            try PQCKeyPairStore.insertIfAbsent(
                candidate,
                descriptor: activeApple,
                publicKeyLength: 2,
                privateKeyLength: 2,
                validatePair: { _ in }
            )
        ) { error in
            guard let storeError = error as? PQCKeyPairStoreError,
                  case .conflictingBackendIdentity(
                algorithm: "ML-DSA-65",
                existing: .liboqs,
                requested: .appleCryptoKit
            ) = storeError else {
                return XCTFail("Unexpected active-backend error: \(error)")
            }
        }
    }

    func testStagedAppleRecordAloneIsNotActiveBackendEvidence() throws {
        let context = isolatedContext()
        let domain = context.domain
        let descriptor = stagedAppleMLDSA65Descriptor(
            identity: "authority-staged-only-\(UUID().uuidString)",
            context: context
        )
        defer {
            try? PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: context.scopeSource
            )
        }

        var candidate = appleMLDSA65Record(descriptor: descriptor)
        defer { PQCKeyPairRecordCodec.wipe(&candidate.privateKey) }
        var persisted = try PQCKeyPairStore.insertIfAbsent(
            candidate,
            descriptor: descriptor,
            publicKeyLength: 1_952,
            privateKeyLength: 64,
            validatePair: { _ in }
        )
        defer { PQCKeyPairRecordCodec.wipe(&persisted.privateKey) }

        XCTAssertEqual(
            try PQCBackendAuthorityStore.installedKeyMaterialEvidence(
                scopeSource: context.scopeSource
            ),
            PQCBackendEvidence(rawValue: 0)
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.previewActiveBackend(
                preferred: .liboqs,
                appleAvailable: true,
                liboqsAvailable: true,
                domain: domain,
                scopeSource: context.scopeSource
            ),
            .liboqs,
            "Staged Apple material must not override the caller's active-backend preference"
        )
        XCTAssertNil(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            ),
            "Staging and capability preview must not write backend authority"
        )

        XCTAssertEqual(
            try PQCBackendAuthorityStore.claim(
                .appleCryptoKit,
                domain: domain,
                scopeSource: context.scopeSource
            ),
            .appleCryptoKit
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            ),
            .appleCryptoKit,
            "Only an explicit active claim may activate the staged backend"
        )
    }

    func testStagedApplePlusLegacyOQSEvidenceSelectsOQS() throws {
        let context = isolatedContext()
        let domain = context.domain
        let identity = "authority-staged-with-legacy-\(UUID().uuidString)"
        let descriptor = stagedAppleMLDSA65Descriptor(
            identity: identity,
            context: context
        )
        let publicService = PQCKeyTags.service("MLDSA", "65", "Pub")
        let privateService = PQCKeyTags.service("MLDSA", "65", "Priv")
        defer {
            try? PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: context.scopeSource
            )
            try? KeychainManager.shared.deleteAPIKey(
                service: publicService,
                account: identity,
                scope: context.keychainScope,
                includeLegacyKeychain: false
            )
            try? KeychainManager.shared.deleteAPIKey(
                service: privateService,
                account: identity,
                scope: context.keychainScope,
                includeLegacyKeychain: false
            )
        }

        var candidate = appleMLDSA65Record(descriptor: descriptor)
        defer { PQCKeyPairRecordCodec.wipe(&candidate.privateKey) }
        var persisted = try PQCKeyPairStore.insertIfAbsent(
            candidate,
            descriptor: descriptor,
            publicKeyLength: 1_952,
            privateKeyLength: 64,
            validatePair: { _ in }
        )
        defer { PQCKeyPairRecordCodec.wipe(&persisted.privateKey) }
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: Data([0xA1]),
            service: publicService,
            account: identity,
            scope: context.keychainScope
        )
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: Data([0xB2]),
            service: privateService,
            account: identity,
            scope: context.keychainScope
        )

        XCTAssertEqual(
            try PQCBackendAuthorityStore.installedKeyMaterialEvidence(
                scopeSource: context.scopeSource
            ),
            .liboqs
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.resolveActiveBackend(
                preferred: .appleCryptoKit,
                appleAvailable: true,
                liboqsAvailable: true,
                domain: domain,
                scopeSource: context.scopeSource
            ),
            .liboqs
        )
        XCTAssertEqual(
            try PQCBackendAuthorityStore.load(
                domain: domain,
                scopeSource: context.scopeSource
            ),
            .liboqs
        )
    }

    func testStagedDescriptorRejectsExplicitCanonicalLocation() {
        let context = isolatedContext()
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: UUID().uuidString,
            authority: .staged,
            authorityDomain: context.domain,
            storageScope: PQCKeyPairStoreStorageScope(
                canonicalLocation: KeychainGenericPasswordLocation(
                    service: "com.skybridge.tests.explicit-staged",
                    account: UUID().uuidString
                ),
                keychainScope: context.keychainScope,
                includeLegacyKeychain: false
            )
        )

        XCTAssertThrowsError(
            try PQCKeyPairStore.load(
                descriptor: descriptor,
                publicKeyLength: 1_952,
                privateKeyLength: 64,
                validatePair: { _ in }
            )
        ) { error in
            guard let storeError = error as? PQCKeyPairStoreError,
                  case .stagedStorageRequiresManagedNamespace = storeError else {
                return XCTFail("Unexpected staged-location error: \(error)")
            }
        }
    }

    func testStagedXWingRecordIsNotMLKEMMLDSABackendEvidence() throws {
        let context = isolatedContext()
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .kem,
            algorithm: "X-Wing-ML-KEM-768-X25519",
            identity: "authority-xwing-\(UUID().uuidString)",
            authority: .staged,
            authorityDomain: context.domain,
            storageScope: context.keyPairStorageScope
        )
        defer { try? PQCKeyPairStore.deleteForTesting(descriptor: descriptor) }
        let candidate = PQCKeyPairRecord(
            algorithmIdentifier: descriptor.algorithmIdentifier,
            publicKey: Data([0x41, 0x42]),
            privateKey: Data([0x43, 0x44])
        )
        _ = try PQCKeyPairStore.insertIfAbsent(
            candidate,
            descriptor: descriptor,
            publicKeyLength: 2,
            privateKeyLength: 2,
            validatePair: { _ in }
        )

        XCTAssertFalse(
            try PQCBackendAuthorityStore.installedKeyMaterialEvidence(
                scopeSource: context.scopeSource
            )
                .contains(.appleCryptoKit),
            "X-Wing has a separate suite and must not elect the ML-KEM/ML-DSA backend"
        )
    }

    func testKnownCanonicalAlgorithmWithWrongLengthsFailsClosed() throws {
        let context = isolatedContext()
        let domain = context.domain
        let descriptor = PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: "authority-invalid-contract-\(UUID().uuidString)",
            authority: .active,
            authorityDomain: context.domain,
            storageScope: context.keyPairStorageScope
        )
        defer {
            try? PQCKeyPairStore.deleteForTesting(descriptor: descriptor)
            try? PQCBackendAuthorityStore.deleteForTesting(
                domain: domain,
                scopeSource: context.scopeSource
            )
        }
        let malformedContract = PQCKeyPairRecord(
            algorithmIdentifier: descriptor.algorithmIdentifier,
            publicKey: Data([0x51, 0x52]),
            privateKey: Data([0x53, 0x54])
        )
        _ = try PQCKeyPairStore.insertIfAbsent(
            malformedContract,
            descriptor: descriptor,
            publicKeyLength: 2,
            privateKeyLength: 2,
            validatePair: { _ in }
        )

        XCTAssertThrowsError(
            try PQCBackendAuthorityStore.installedKeyMaterialEvidence(
                scopeSource: context.scopeSource
            )
        ) { error in
            XCTAssertEqual(
                error as? PQCBackendAuthorityError,
                .invalidCanonicalKeyContract(
                    algorithm: "apple-cryptokit/signature/ML-DSA-65",
                    expectedPublicKeyLength: 1_952,
                    actualPublicKeyLength: 2,
                    expectedPrivateKeyLength: 64,
                    actualPrivateKeyLength: 2
                )
            )
        }
    }

    private func isolatedContext(
        domain: PQCBackendAuthorityDomain? = nil,
        includeUnscopedRead: Bool = false
    ) -> StorageContext {
        let identifier = UUID().uuidString
        let accessGroup = "group.com.skybridge.tests.authority.\(identifier)"
        return StorageContext(
            domain: domain ?? .testing(identifier),
            keychainScope: KeychainGenericPasswordScope(
                accessibility: .afterFirstUnlockThisDeviceOnly,
                writeAccessGroup: accessGroup,
                readAccessGroups: includeUnscopedRead
                    ? [accessGroup, nil]
                    : [accessGroup],
                usesDataProtectionKeychain: true,
                synchronizable: false
            )
        )
    }

    private func legacyMigrationFixture(
        context: StorageContext,
        algorithm: String,
        purpose: PQCKeyPairStorePurpose
    ) -> LegacyMigrationFixture {
        let identity = "legacy-fixture-\(UUID().uuidString)"
        let publicLocation = KeychainGenericPasswordLocation(
            service: "com.skybridge.tests.pqc-legacy-public.\(UUID().uuidString)",
            account: identity
        )
        let privateLocation = KeychainGenericPasswordLocation(
            service: "com.skybridge.tests.pqc-legacy-private.\(UUID().uuidString)",
            account: identity
        )
        return LegacyMigrationFixture(
            descriptor: PQCKeyPairStoreDescriptor(
                backend: .liboqs,
                purpose: purpose,
                algorithm: algorithm,
                identity: identity,
                authority: .staged,
                authorityDomain: context.domain,
                storageScope: context.keyPairStorageScope
            ),
            storage: PQCKeyPairStoreLegacyKeyPair(
                publicKeyLocation: publicLocation,
                privateKeyLocation: privateLocation,
                keychainScopeSource: context.scopeSource,
                includeLegacyKeychain: true
            ),
            publicLocation: publicLocation,
            privateLocation: privateLocation
        )
    }

    private func seedLegacyRecord(
        _ record: PQCKeyPairRecord,
        fixture: LegacyMigrationFixture,
        context: StorageContext
    ) throws {
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: record.publicKey,
            service: fixture.publicLocation.service,
            account: fixture.publicLocation.account,
            scope: context.keychainScope
        )
        _ = try KeychainManager.shared.insertKeyIfAbsent(
            data: record.privateKey,
            service: fixture.privateLocation.service,
            account: fixture.privateLocation.account,
            scope: context.keychainScope
        )
    }

    private func legacyCandidateCount(
        _ location: KeychainGenericPasswordLocation
    ) throws -> Int {
        var candidates = try KeychainManager.shared
            .legacyGenericPasswordCandidatesStrict(
                service: location.service,
                account: location.account
            )
        defer {
            for index in candidates.indices {
                PQCKeyPairRecordCodec.wipe(&candidates[index].data)
            }
        }
        return candidates.count
    }

    private func cleanupLegacyMigrationFixture(
        _ fixture: LegacyMigrationFixture,
        context: StorageContext
    ) {
        try? PQCKeyPairStore.deleteForTesting(descriptor: fixture.descriptor)
        try? KeychainManager.shared.deleteAPIKey(
            service: fixture.publicLocation.service,
            account: fixture.publicLocation.account,
            scope: context.keychainScope
        )
        try? KeychainManager.shared.deleteAPIKey(
            service: fixture.privateLocation.service,
            account: fixture.privateLocation.account,
            scope: context.keychainScope
        )
    }

    private func stagedAppleMLDSA65Descriptor(
        identity: String,
        context: StorageContext
    ) -> PQCKeyPairStoreDescriptor {
        PQCKeyPairStoreDescriptor(
            backend: .appleCryptoKit,
            purpose: .signature,
            algorithm: "ML-DSA-65",
            identity: identity,
            authority: .staged,
            authorityDomain: context.domain,
            storageScope: context.keyPairStorageScope
        )
    }

    private func appleMLDSA65Record(
        descriptor: PQCKeyPairStoreDescriptor
    ) -> PQCKeyPairRecord {
        PQCKeyPairRecord(
            algorithmIdentifier: descriptor.algorithmIdentifier,
            publicKey: Data(repeating: 0xA5, count: 1_952),
            privateKey: Data(repeating: 0x5A, count: 64)
        )
    }
}
