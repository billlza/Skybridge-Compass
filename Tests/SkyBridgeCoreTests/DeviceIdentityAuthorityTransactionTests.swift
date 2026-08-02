import CryptoKit
import os
import Security
import XCTest
@_spi(SkyBridgeSmokeDiagnostics) @testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class DeviceIdentityAuthorityTransactionTests: XCTestCase {
    private enum FakeStoreError: Error, LocalizedError, Sendable, Equatable {
        case cleanupRefused

        var errorDescription: String? {
            "fake cleanup refused"
        }
    }

    private struct FakeStore: DeviceIdentityAuthorityTransactionStore {
        struct State: Sendable {
            var authority: DeviceIdentityAuthorityRecord?
            var keys: [String: DeviceIdentityPrivateKeyMetadata] = [:]
            var deletedTags: Set<String> = []
            var cleanupFailureTags: Set<String> = []
            var hideAuthorityOnLoad = false
        }

        let state = OSAllocatedUnfairLock(initialState: State())

        func loadAuthority() throws -> DeviceIdentityAuthorityRecord? {
            state.withLock { current in
                current.hideAuthorityOnLoad ? nil : current.authority
            }
        }

        func insertAuthorityIfAbsent(
            _ record: DeviceIdentityAuthorityRecord
        ) throws -> KeychainInsertResult {
            state.withLock { current in
                guard current.authority == nil else { return .alreadyExists }
                current.authority = record
                return .inserted
            }
        }

        func privateKeyMetadata(
            forPrivateKeyApplicationTag tag: String
        ) throws -> DeviceIdentityPrivateKeyMetadata? {
            state.withLock { $0.keys[tag] }
        }

        func insertSoftwarePrivateKeyIfAbsent(
            _ privateKeyRepresentation: Data,
            expectedPublicKey: Data,
            applicationTag: String
        ) throws -> KeychainInsertResult {
            guard !privateKeyRepresentation.isEmpty else {
                throw DeviceIdentityAuthorityError
                    .legacyPrivateKeyNotExportableRequiresRotationAndRepinning
            }
            return state.withLock { current in
                guard current.keys[applicationTag] == nil else {
                    return .alreadyExists
                }
                current.keys[applicationTag] = DeviceIdentityPrivateKeyMetadata(
                    publicKey: expectedPublicKey,
                    isSecureEnclave: false
                )
                return .inserted
            }
        }

        func deletePrivateKey(applicationTag: String) throws {
            try state.withLock { current in
                if current.cleanupFailureTags.contains(applicationTag) {
                    throw FakeStoreError.cleanupRefused
                }
                current.keys.removeValue(forKey: applicationTag)
                current.deletedTags.insert(applicationTag)
            }
        }

        func stage(
            _ record: DeviceIdentityAuthorityRecord,
            metadata: DeviceIdentityPrivateKeyMetadata? = nil
        ) {
            state.withLock { current in
                current.keys[record.privateKeyApplicationTag] = metadata
                    ?? DeviceIdentityPrivateKeyMetadata(
                        publicKey: record.publicKey,
                        isSecureEnclave: record.isSecureEnclave
                    )
            }
        }

        func seedAuthority(_ record: DeviceIdentityAuthorityRecord) {
            state.withLock { $0.authority = record }
        }

        func setCleanupFailure(for tag: String) {
            _ = state.withLock { $0.cleanupFailureTags.insert(tag) }
        }

        func setHideAuthorityOnLoad() {
            state.withLock { $0.hideAuthorityOnLoad = true }
        }

        func snapshot() -> State {
            state.withLock { $0 }
        }
    }

    private actor CallbackProbe {
        private var inputs: [Data] = []

        func sign(_ data: Data) -> Data {
            inputs.append(data)
            return Data(SHA256.hash(data: data))
        }

        func receivedInputs() -> [Data] {
            inputs
        }
    }

    private enum ClaimOutcome: Sendable {
        case winner(DeviceIdentityAuthorityRecord)
        case failure(String)
    }

    func testConcurrentDifferentCandidatesConvergeAndCleanEveryLoser() async throws {
        let store = FakeStore()
        let createdAt = Date(timeIntervalSince1970: 1_720_000_000)
        let candidates = (0..<32).map { index in
            makeRecord(deviceId: "candidate-\(index)", createdAt: createdAt)
        }
        for candidate in candidates {
            store.stage(candidate)
        }

        let outcomes = await withTaskGroup(of: ClaimOutcome.self) { group in
            for candidate in candidates {
                group.addTask {
                    do {
                        return .winner(
                            try DeviceIdentityAuthorityTransaction.claimCandidate(
                                candidate,
                                using: store
                            )
                        )
                    } catch {
                        return .failure(error.localizedDescription)
                    }
                }
            }
            var values: [ClaimOutcome] = []
            for await value in group {
                values.append(value)
            }
            return values
        }

        let winner = try XCTUnwrap(store.snapshot().authority)
        XCTAssertEqual(outcomes.count, candidates.count)
        for outcome in outcomes {
            switch outcome {
            case .winner(let resolved):
                XCTAssertEqual(resolved, winner)
            case .failure(let reason):
                XCTFail("Unexpected claim failure: \(reason)")
            }
        }
        let snapshot = store.snapshot()
        XCTAssertEqual(Set(snapshot.keys.keys), [winner.privateKeyApplicationTag])
        XCTAssertEqual(snapshot.deletedTags.count, candidates.count - 1)

        let resolvedAgain = try XCTUnwrap(
            DeviceIdentityAuthorityTransaction.resolve(using: store)
        )
        XCTAssertEqual(resolvedAgain.createdAt, createdAt)
        XCTAssertEqual(resolvedAgain, winner)
    }

    func testWinnerMissingAfterClaimFailsClosedWithoutDeletingPossibleWinner() throws {
        let store = FakeStore()
        let candidate = makeRecord(deviceId: "hidden-winner")
        store.stage(candidate)
        store.setHideAuthorityOnLoad()

        XCTAssertThrowsError(
            try DeviceIdentityAuthorityTransaction.claimCandidate(
                candidate,
                using: store
            )
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityAuthorityError,
                .authorityWinnerMissing
            )
        }
        XCTAssertNotNil(
            store.snapshot().keys[candidate.privateKeyApplicationTag],
            "Visibility uncertainty must not delete a key that may be authoritative"
        )
    }

    func testAuthorityWithMissingWinnerKeyFailsClosed() throws {
        let store = FakeStore()
        let winner = makeRecord(deviceId: "missing-key")
        store.seedAuthority(winner)

        XCTAssertThrowsError(
            try DeviceIdentityAuthorityTransaction.resolve(using: store)
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityAuthorityError,
                .authorityWinnerKeyMissing(winner.privateKeyApplicationTag)
            )
        }
    }

    func testAuthorityPublicKeyConflictFailsClosed() throws {
        let store = FakeStore()
        let winner = makeRecord(deviceId: "public-conflict")
        let other = makeRecord(deviceId: "other")
        store.seedAuthority(winner)
        store.stage(
            winner,
            metadata: DeviceIdentityPrivateKeyMetadata(
                publicKey: other.publicKey,
                isSecureEnclave: winner.isSecureEnclave
            )
        )

        XCTAssertThrowsError(
            try DeviceIdentityAuthorityTransaction.resolve(using: store)
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityAuthorityError,
                .authorityWinnerPublicKeyMismatch
            )
        }
    }

    func testAuthoritySecureEnclaveMetadataConflictFailsClosed() throws {
        let store = FakeStore()
        let winner = makeRecord(deviceId: "se-conflict", isSecureEnclave: true)
        store.seedAuthority(winner)
        store.stage(
            winner,
            metadata: DeviceIdentityPrivateKeyMetadata(
                publicKey: winner.publicKey,
                isSecureEnclave: false
            )
        )

        XCTAssertThrowsError(
            try DeviceIdentityAuthorityTransaction.resolve(using: store)
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityAuthorityError,
                .authorityWinnerSecureEnclaveMismatch
            )
        }
    }

    func testLoserCleanupFailureIsExplicit() throws {
        let store = FakeStore()
        let winner = makeRecord(deviceId: "winner")
        let loser = makeRecord(deviceId: "loser")
        store.stage(winner)
        store.stage(loser)
        store.seedAuthority(winner)
        store.setCleanupFailure(for: loser.privateKeyApplicationTag)

        XCTAssertThrowsError(
            try DeviceIdentityAuthorityTransaction.claimCandidate(
                loser,
                using: store
            )
        ) { error in
            guard let authorityError = error as? DeviceIdentityAuthorityError,
                  case .candidateCleanupFailed = authorityError else {
                return XCTFail("Expected explicit cleanup failure, got \(error)")
            }
        }
        XCTAssertNotNil(store.snapshot().keys[loser.privateKeyApplicationTag])
    }

    func testLegacySoftwareMigrationPreservesIdentityAndCreatedAt() throws {
        let store = FakeStore()
        let createdAt = Date(timeIntervalSince1970: 1_650_000_000)
        let legacy = makeRecord(deviceId: "legacy-software", createdAt: createdAt)
        let candidateTag = DeviceIdentityAuthorityRecord.uniquePrivateKeyApplicationTag()
        var privateKeyRepresentation = Data(repeating: 0xA5, count: 32)
        defer { privateKeyRepresentation.secureErase() }

        let winner = try DeviceIdentityAuthorityTransaction.migrateLegacy(
            .software(
                authority: legacy,
                privateKeyRepresentation: privateKeyRepresentation
            ),
            candidateApplicationTag: candidateTag,
            using: store
        )

        XCTAssertEqual(winner.deviceId, legacy.deviceId)
        XCTAssertEqual(winner.publicKey, legacy.publicKey)
        XCTAssertEqual(winner.publicKeyFingerprint, legacy.publicKeyFingerprint)
        XCTAssertEqual(winner.createdAt, createdAt)
        XCTAssertEqual(winner.privateKeyApplicationTag, candidateTag)
        XCTAssertEqual(Set(store.snapshot().keys.keys), [candidateTag])
    }

    func testLegacySoftwareMigrationRejectsInvalidIdentityBeforePrivateKeyInsert() throws {
        let store = FakeStore()
        let valid = makeRecord(deviceId: "valid-legacy")
        let invalid = DeviceIdentityAuthorityRecord(
            deviceId: "legacy\0identity",
            publicKey: valid.publicKey,
            publicKeyFingerprint: valid.publicKeyFingerprint,
            privateKeyApplicationTag: valid.privateKeyApplicationTag,
            isSecureEnclave: false,
            createdAt: valid.createdAt
        )

        XCTAssertThrowsError(
            try DeviceIdentityAuthorityTransaction.migrateLegacy(
                .software(
                    authority: invalid,
                    privateKeyRepresentation: Data(repeating: 0xA5, count: 32)
                ),
                candidateApplicationTag: DeviceIdentityAuthorityRecord
                    .uniquePrivateKeyApplicationTag(),
                using: store
            )
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityAuthorityError,
                .invalidDeviceId
            )
        }
        let snapshot = store.snapshot()
        XCTAssertNil(snapshot.authority)
        XCTAssertTrue(snapshot.keys.isEmpty)
        XCTAssertTrue(snapshot.deletedTags.isEmpty)
    }

    func testLegacySecureEnclaveRequiresExplicitRotationAndRepinning() throws {
        let store = FakeStore()

        XCTAssertThrowsError(
            try DeviceIdentityAuthorityTransaction.migrateLegacy(
                .secureEnclave,
                candidateApplicationTag: DeviceIdentityAuthorityRecord
                    .uniquePrivateKeyApplicationTag(),
                using: store
            )
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityAuthorityError,
                .legacySecureEnclaveRequiresRotationAndRepinning
            )
        }
        XCTAssertNil(store.snapshot().authority)
        XCTAssertTrue(store.snapshot().keys.isEmpty)
    }

    func testAuthorityResidueAuditAcceptsMatchingPartialRemnants() throws {
        let authority = makeRecord(
            deviceId: "matching-remnants",
            createdAt: Date(timeIntervalSince1970: 1_680_000_000)
        )
        let legacy = DeviceIdentityLegacyState(
            keyInfos: [],
            deviceIds: [authority.deviceId],
            privateKeyMetadata: [
                DeviceIdentityPrivateKeyMetadata(
                    publicKey: authority.publicKey,
                    isSecureEnclave: authority.isSecureEnclave
                )
            ]
        )

        let resolution = try DeviceIdentityLegacyReconciliation
            .resolveValidatedAuthority(
                authority,
                retaining: legacy
            )
        XCTAssertEqual(resolution.authority, authority)
        XCTAssertFalse(resolution.residueAudit.hasConflicts)
        XCTAssertEqual(
            resolution.residueAudit.deviceIds,
            DeviceIdentityLegacyComparisonCount(matching: 1, conflicting: 0)
        )
        XCTAssertEqual(
            resolution.residueAudit.privateKeys,
            DeviceIdentityLegacyComparisonCount(matching: 1, conflicting: 0)
        )
    }

    func testAuthorityAuditClassifiesEachLegacyValueWithoutExposingIt() throws {
        let authority = makeRecord(
            deviceId: "audit-authority",
            createdAt: Date(timeIntervalSince1970: 1_681_000_000)
        )
        let conflicting = makeRecord(
            deviceId: "audit-conflict",
            createdAt: authority.createdAt
        )
        let matchingMetadata = DeviceIdentityPrivateKeyMetadata(
            publicKey: authority.publicKey,
            isSecureEnclave: authority.isSecureEnclave
        )
        let conflictingMetadata = DeviceIdentityPrivateKeyMetadata(
            publicKey: conflicting.publicKey,
            isSecureEnclave: conflicting.isSecureEnclave
        )
        let legacy = DeviceIdentityLegacyState(
            keyInfos: [
                legacyKeyInfo(from: authority),
                legacyKeyInfo(from: conflicting)
            ],
            deviceIds: [authority.deviceId, conflicting.deviceId],
            privateKeyMetadata: [matchingMetadata, conflictingMetadata]
        )

        let audit = try DeviceIdentityLegacyReconciliation.audit(
            legacy,
            against: authority
        )

        XCTAssertEqual(
            audit.keyInfos,
            DeviceIdentityLegacyComparisonCount(matching: 1, conflicting: 1)
        )
        XCTAssertEqual(
            audit.deviceIds,
            DeviceIdentityLegacyComparisonCount(matching: 1, conflicting: 1)
        )
        XCTAssertEqual(
            audit.privateKeys,
            DeviceIdentityLegacyComparisonCount(matching: 1, conflicting: 1)
        )
        XCTAssertTrue(audit.hasConflicts)
    }

    func testAuthorityAuditTreatsCreatedAtOnlyMismatchAsConflict() throws {
        let authority = makeRecord(
            deviceId: "created-at-authority",
            createdAt: Date(timeIntervalSince1970: 1_682_000_000)
        )
        let legacyKeyInfo = DeviceIdentityKeyInfo(
            deviceId: authority.deviceId,
            pubKeyFP: authority.publicKeyFingerprint,
            publicKey: authority.publicKey,
            keyType: .p256Signing,
            createdAt: authority.createdAt.addingTimeInterval(1),
            isSecureEnclave: authority.isSecureEnclave
        )

        let audit = try DeviceIdentityLegacyReconciliation.audit(
            DeviceIdentityLegacyState(keyInfos: [legacyKeyInfo]),
            against: authority
        )

        XCTAssertEqual(audit.keyInfos.matching, 0)
        XCTAssertEqual(audit.keyInfos.conflicting, 1)
        XCTAssertTrue(audit.hasConflicts)
    }

    func testLegacyAuditWithoutAuthorityClassifiesConflictingPrivateKeys() throws {
        let reference = makeRecord(deviceId: "legacy-reference")
        let conflicting = makeRecord(deviceId: "legacy-conflict")
        let audit = try XCTUnwrap(
            DeviceIdentityLegacyReconciliation.auditCoherenceWithoutAuthority(
                DeviceIdentityLegacyState(
                    keyInfos: [legacyKeyInfo(from: reference)],
                    deviceIds: [reference.deviceId],
                    privateKeyMetadata: [
                        DeviceIdentityPrivateKeyMetadata(
                            publicKey: reference.publicKey,
                            isSecureEnclave: reference.isSecureEnclave
                        ),
                        DeviceIdentityPrivateKeyMetadata(
                            publicKey: conflicting.publicKey,
                            isSecureEnclave: conflicting.isSecureEnclave
                        )
                    ]
                )
            )
        )

        XCTAssertEqual(audit.keyInfos.matching, 1)
        XCTAssertEqual(audit.deviceIds.matching, 1)
        XCTAssertEqual(audit.privateKeys.matching, 1)
        XCTAssertEqual(audit.privateKeys.conflicting, 1)
        XCTAssertTrue(audit.hasConflicts)
    }

    func testLegacyAuditWithoutKeyInfoHasNoComparisonBasis() throws {
        let audit = try DeviceIdentityLegacyReconciliation
            .auditCoherenceWithoutAuthority(
                DeviceIdentityLegacyState(deviceIds: ["orphan-device-id"])
            )
        XCTAssertNil(audit)
    }

    func testLegacyAuditNamespaceClassificationNeverReturnsAccessGroupNames() throws {
        let sharedGroup = "TEAM.group.com.skybridge.compass"
        let shared = LegacySecItemLocation(
            actualAccessGroup: sharedGroup,
            usesDataProtectionKeychain: true,
            persistentReference: Data([0x01])
        )
        let other = LegacySecItemLocation(
            actualAccessGroup: "TEAM.com.skybridge.compass",
            usesDataProtectionKeychain: true,
            persistentReference: Data([0x02])
        )
        let legacy = LegacySecItemLocation(
            actualAccessGroup: nil,
            usesDataProtectionKeychain: false,
            persistentReference: Data([0x03])
        )

        XCTAssertEqual(
            DeviceIdentityKeyManager.legacyAuditNamespace(
                for: shared,
                authoritativeAccessGroup: sharedGroup
            ),
            .sharedDataProtection
        )
        XCTAssertEqual(
            DeviceIdentityKeyManager.legacyAuditNamespace(
                for: other,
                authoritativeAccessGroup: sharedGroup
            ),
            .otherDataProtection
        )
        XCTAssertEqual(
            DeviceIdentityKeyManager.legacyAuditNamespace(
                for: legacy,
                authoritativeAccessGroup: sharedGroup
            ),
            .legacyFileKeychain
        )
    }

    func testLegacyAuditJSONContainsOnlyFixedCategoriesAndCounts() throws {
        let zero = DeviceIdentityLegacyAuditValueCount(
            matching: 0,
            conflicting: 0,
            unresolved: 0
        )
        let report = DeviceIdentityLegacyAuditReport(
            schemaVersion: 2,
            state: .conflictingLegacyRemnants,
            authorityPresent: true,
            authorityKeyValidated: true,
            comparisonBasis: .sharedAuthority,
            stableAcrossReads: true,
            inspectionStatus: .complete(hasConflicts: true),
            namespaces: [
                DeviceIdentityLegacyAuditNamespaceSummary(
                    namespace: .otherDataProtection,
                    privateKeys: DeviceIdentityLegacyAuditValueCount(
                        matching: 0,
                        conflicting: 1,
                        unresolved: 0
                    ),
                    keyInfos: zero,
                    deviceIds: zero,
                    mismatches: [
                        DeviceIdentityLegacyAuditMismatchCount(
                            dimension: .privateKeyPublicKey,
                            count: 1
                        )
                    ]
                )
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(report)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        XCTAssertTrue(json.contains("\"state\":\"conflicting-legacy-remnants\""))
        XCTAssertTrue(json.contains("\"namespace\":\"other-data-protection\""))
        XCTAssertTrue(json.contains("\"conflicting\":1"))
        XCTAssertTrue(json.contains("\"stableAcrossReads\":true"))
        XCTAssertTrue(json.contains("\"inspectionComplete\":true"))
        XCTAssertTrue(json.contains("\"hasConflicts\":true"))
        XCTAssertTrue(json.contains("\"dimension\":\"private-key-public-key\""))
        for forbidden in [
            "TEAM.group.com.skybridge.compass",
            "secret-device-id-value",
            "secret-public-key-value",
            "secret-fingerprint-value",
            "secret-persistent-reference-value",
            "secret-application-tag-value"
        ] {
            XCTAssertFalse(json.contains(forbidden), "Audit JSON leaked \(forbidden)")
        }
    }

    func testValidatedAuthorityRetainsMatchingLegacyAliases() throws {
        let authority = makeRecord(deviceId: "retained-match")
        let legacy = DeviceIdentityLegacyState(
            keyInfos: [legacyKeyInfo(from: authority)],
            deviceIds: [authority.deviceId],
            privateKeyMetadata: [
                DeviceIdentityPrivateKeyMetadata(
                    publicKey: authority.publicKey,
                    isSecureEnclave: authority.isSecureEnclave
                )
            ]
        )

        let resolution = try DeviceIdentityLegacyReconciliation
            .resolveValidatedAuthority(
                authority,
                retaining: legacy
            )

        XCTAssertEqual(resolution.authority, authority)
        XCTAssertFalse(resolution.residueAudit.hasConflicts)
        XCTAssertEqual(resolution.residueAudit.keyInfos.matching, 1)
        XCTAssertEqual(resolution.residueAudit.deviceIds.matching, 1)
        XCTAssertEqual(resolution.residueAudit.privateKeys.matching, 1)
    }

    func testValidatedAuthoritySurvivesConflictingResidueAndReportsIt() throws {
        let authority = makeRecord(deviceId: "retained-authority")
        let conflicting = makeRecord(deviceId: "retained-conflict")
        let legacy = DeviceIdentityLegacyState(
            keyInfos: [legacyKeyInfo(from: conflicting)],
            deviceIds: [conflicting.deviceId],
            privateKeyMetadata: [
                DeviceIdentityPrivateKeyMetadata(
                    publicKey: conflicting.publicKey,
                    isSecureEnclave: false
                )
            ]
        )

        let resolution = try DeviceIdentityLegacyReconciliation
            .resolveValidatedAuthority(
                authority,
                retaining: legacy
            )

        XCTAssertEqual(resolution.authority, authority)
        XCTAssertTrue(resolution.residueAudit.hasConflicts)
        XCTAssertEqual(resolution.residueAudit.keyInfos.conflicting, 1)
        XCTAssertEqual(resolution.residueAudit.deviceIds.conflicting, 1)
        XCTAssertEqual(resolution.residueAudit.privateKeys.conflicting, 1)
    }

    func testCommittedLegacyRecoverySelectsTheUniqueKeyInfoBoundPrivateKey() throws {
        let committed = makeRecord(deviceId: "committed-legacy")
        let abandonedA = makeRecord(deviceId: "abandoned-a")
        let abandonedB = makeRecord(deviceId: "abandoned-b")
        let committedKeyInfo = legacyKeyInfo(from: committed)
        let candidates = [abandonedA, committed, abandonedB].enumerated().map {
            index, record in
            DeviceIdentityLegacyPrivateKeyCandidate(
                location: LegacySecItemLocation(
                    actualAccessGroup: nil,
                    usesDataProtectionKeychain: false,
                    persistentReference: Data([UInt8(index + 1)])
                ),
                metadata: DeviceIdentityPrivateKeyMetadata(
                    publicKey: record.publicKey,
                    isSecureEnclave: record.isSecureEnclave
                )
            )
        }
        let state = DeviceIdentityLegacyState(
            keyInfos: [committedKeyInfo],
            deviceIds: ["partially-staged-device-id"],
            privateKeyMetadata: candidates.map(\.metadata)
        )

        let selectedKeyInfo = try DeviceIdentityLegacyReconciliation
            .committedMigrationKeyInfo(from: state)
        let selectedKey = try DeviceIdentityLegacyReconciliation
            .uniqueCommittedMigrationPrivateKey(
                from: candidates,
                matching: selectedKeyInfo
            )

        XCTAssertEqual(selectedKeyInfo, committedKeyInfo)
        XCTAssertEqual(selectedKey, candidates[1])
    }

    func testCommittedLegacyRecoveryRejectsAmbiguousMatchingPrivateKeys() throws {
        let committed = makeRecord(deviceId: "ambiguous-legacy")
        let keyInfo = legacyKeyInfo(from: committed)
        let metadata = DeviceIdentityPrivateKeyMetadata(
            publicKey: committed.publicKey,
            isSecureEnclave: committed.isSecureEnclave
        )
        let candidates = (1...2).map { value in
            DeviceIdentityLegacyPrivateKeyCandidate(
                location: LegacySecItemLocation(
                    actualAccessGroup: nil,
                    usesDataProtectionKeychain: false,
                    persistentReference: Data([UInt8(value)])
                ),
                metadata: metadata
            )
        }

        XCTAssertThrowsError(
            try DeviceIdentityLegacyReconciliation
                .uniqueCommittedMigrationPrivateKey(
                    from: candidates,
                    matching: keyInfo
                )
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityAuthorityError,
                .legacyIdentityConflictsWithAuthority
            )
        }
    }

    func testCommittedLegacyRecoveryRejectsDivergentKeyInfoRecords() throws {
        let first = makeRecord(deviceId: "first-commit")
        let second = makeRecord(deviceId: "second-commit")
        let state = DeviceIdentityLegacyState(
            keyInfos: [legacyKeyInfo(from: first), legacyKeyInfo(from: second)]
        )

        XCTAssertThrowsError(
            try DeviceIdentityLegacyReconciliation
                .committedMigrationKeyInfo(from: state)
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityAuthorityError,
                .legacyIdentityConflictsWithAuthority
            )
        }
    }

    func testAuthorityRecordRejectsNonCanonicalUniqueTag() throws {
        let valid = makeRecord(deviceId: "strict-tag")
        let invalid = DeviceIdentityAuthorityRecord(
            deviceId: valid.deviceId,
            publicKey: valid.publicKey,
            publicKeyFingerprint: valid.publicKeyFingerprint,
            privateKeyApplicationTag: DeviceIdentityAuthorityRecord
                .privateKeyTagPrefix + "not-a-uuid",
            isSecureEnclave: valid.isSecureEnclave,
            createdAt: valid.createdAt
        )

        XCTAssertThrowsError(try invalid.validated()) { error in
            XCTAssertEqual(
                error as? DeviceIdentityAuthorityError,
                .invalidPrivateKeyApplicationTag
            )
        }
    }

    func testPublicErrorBoundaryPreservesRotationAndConflictSemantics() {
        guard case .identityMigrationRequiresRotationAndRepinning =
            DeviceIdentityKeyManager.publicIdentityError(
                for: DeviceIdentityAuthorityError
                    .legacySecureEnclaveRequiresRotationAndRepinning
            ) else {
            return XCTFail("Legacy Secure Enclave migration must remain typed")
        }
        guard case .authorityConflict = DeviceIdentityKeyManager.publicIdentityError(
            for: DeviceIdentityAuthorityError.legacyIdentityConflictsWithAuthority
        ) else {
            return XCTFail("Authority conflicts must remain typed")
        }
        guard case .corruptIdentityAuthority = DeviceIdentityKeyManager.publicIdentityError(
            for: DeviceIdentityAuthorityError.authorityWinnerPublicKeyMismatch
        ) else {
            return XCTFail("Corrupt authority must remain typed")
        }
        guard case .identityMigrationRequired = DeviceIdentityKeyManager
            .publicIdentityError(
                for: DeviceIdentityAuthorityError
                    .legacyIdentityRequiresExplicitMigration
            ) else {
            return XCTFail("Read-only resolution must expose pending migration")
        }
    }

    func testPublicIdentityErrorNeverExposesAuthorityStorageMetadata() {
        let secretTag = "com.skybridge.secret.identity-tag"
        let secretService = "com.skybridge.secret.service"
        let secretAccount = "secret-account"
        let errors: [Error] = [
            DeviceIdentityAuthorityError.authorityWinnerKeyMissing(secretTag),
            DeviceIdentityAuthorityError.immutableGenericPasswordConflict(
                service: secretService,
                account: secretAccount
            ),
            DeviceIdentityAuthorityError.candidateCleanupFailed("secret-reason")
        ]

        for error in errors {
            let description = DeviceIdentityKeyManager.publicIdentityError(
                for: error
            ).localizedDescription
            XCTAssertFalse(description.contains(secretTag))
            XCTAssertFalse(description.contains(secretService))
            XCTAssertFalse(description.contains(secretAccount))
            XCTAssertFalse(description.contains("secret-reason"))
        }
    }

    func testLegacyResidueInspectionMapsOnlyKnownBoundaryFailures() {
        XCTAssertEqual(
            DeviceIdentityKeyManager.legacyResidueInspectionFailureReason(
                for: KeychainError.unexpectedError(errSecInteractionNotAllowed)
            ),
            .accessDenied
        )
        XCTAssertEqual(
            DeviceIdentityKeyManager.legacyResidueInspectionFailureReason(
                for: DeviceIdentityKeyError.keychainError(errSecNotAvailable)
            ),
            .keychainUnavailable
        )
        XCTAssertEqual(
            DeviceIdentityKeyManager.legacyResidueInspectionFailureReason(
                for: DeviceIdentityAuthorityError
                    .legacyIdentityIncomplete("must-not-escape")
            ),
            .malformedAttributes
        )
        XCTAssertNil(
            DeviceIdentityKeyManager.legacyResidueInspectionFailureReason(
                for: FakeStoreError.cleanupRefused
            ),
            "Unknown programming errors must not be downgraded"
        )
    }

    func testLegacyResidueInspectionStatusCannotRepresentUnavailableAsClean() throws {
        let status = DeviceIdentityLegacyResidueInspectionStatus.unavailable(
            .malformedKeyInfo
        )
        XCTAssertFalse(status.inspectionComplete)
        XCTAssertNil(status.hasConflicts)
        XCTAssertEqual(status.failureReason, .malformedKeyInfo)

        let encoded = try JSONEncoder().encode(status)
        let json = try XCTUnwrap(
            String(data: encoded, encoding: .utf8)
        )
        XCTAssertTrue(json.contains("malformed-key-info"))
        XCTAssertFalse(json.contains("privateKeyApplicationTag"))
        XCTAssertFalse(json.contains("accessGroup"))
        XCTAssertFalse(json.contains("persistentReference"))

        let incoherent = Data(
            #"{"schemaVersion":1,"inspectionComplete":true,"failureReason":"malformed-key-info"}"#.utf8
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                DeviceIdentityLegacyResidueInspectionStatus.self,
                from: incoherent
            )
        )
    }

    func testManagerCallbackUsesInjectedActorSigner() async throws {
        let probe = CallbackProbe()
        let callback = DeviceIdentityManagerSigningCallback { data in
            await probe.sign(data)
        }
        let message = Data("winner-bound-callback".utf8)

        let signature = try await callback.sign(data: message)
        let receivedInputs = await probe.receivedInputs()
        XCTAssertEqual(signature, Data(SHA256.hash(data: message)))
        XCTAssertEqual(receivedInputs, [message])
    }

    func testProductionCallbackDelegatesToAuthorityResolvingManagerPath() throws {
        let source = try repositorySource(
            "Sources/SkyBridgeCore/P2P/DeviceIdentityKeyManager.swift"
        )
        XCTAssertTrue(
            source.contains("return DeviceIdentityManagerSigningCallback(manager: self)")
        )
        XCTAssertFalse(
            source.contains("return SecureEnclaveSigningCallback(keyTag: KeychainConstants.signingKeyTag)")
        )
    }

    private func makeRecord(
        deviceId: String,
        isSecureEnclave: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> DeviceIdentityAuthorityRecord {
        let privateKey = P256.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.x963Representation
        return DeviceIdentityAuthorityRecord(
            deviceId: deviceId,
            publicKey: publicKey,
            publicKeyFingerprint: DeviceIdentityAuthorityRecord.fingerprint(
                for: publicKey
            ),
            privateKeyApplicationTag: DeviceIdentityAuthorityRecord
                .uniquePrivateKeyApplicationTag(),
            isSecureEnclave: isSecureEnclave,
            createdAt: createdAt
        )
    }

    private func legacyKeyInfo(
        from record: DeviceIdentityAuthorityRecord
    ) -> DeviceIdentityKeyInfo {
        DeviceIdentityKeyInfo(
            deviceId: record.deviceId,
            pubKeyFP: record.publicKeyFingerprint,
            publicKey: record.publicKey,
            keyType: .p256Signing,
            createdAt: record.createdAt,
            isSecureEnclave: record.isSecureEnclave
        )
    }

    private func repositorySource(_ relativePath: String) throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: repoRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
