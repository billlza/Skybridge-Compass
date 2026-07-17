import CryptoKit
import os
import XCTest
@testable import SkyBridgeCore

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

    func testAuthorityReconciliationAcceptsMatchingPartialRemnants() throws {
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

        XCTAssertNoThrow(
            try DeviceIdentityLegacyReconciliation.validate(
                legacy,
                matches: authority
            )
        )
    }

    func testAuthorityReconciliationConflictPersistsAcrossRetry() throws {
        let authority = makeRecord(deviceId: "authority-a")
        let conflicting = makeRecord(deviceId: "legacy-b")
        let legacy = DeviceIdentityLegacyState(
            keyInfos: [legacyKeyInfo(from: conflicting)],
            deviceIds: [conflicting.deviceId],
            privateKeyMetadata: [
                DeviceIdentityPrivateKeyMetadata(
                    publicKey: conflicting.publicKey,
                    isSecureEnclave: conflicting.isSecureEnclave
                )
            ]
        )

        for _ in 0..<2 {
            XCTAssertThrowsError(
                try DeviceIdentityLegacyReconciliation.validate(
                    legacy,
                    matches: authority
                )
            ) { error in
                XCTAssertEqual(
                    error as? DeviceIdentityAuthorityError,
                    .legacyIdentityConflictsWithAuthority
                )
            }
        }
    }

    func testAuthorityReconciliationRetriesCleanupAfterCrashWindow() throws {
        let authority = makeRecord(deviceId: "cleanup-retry")
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
        var cleanupAttempts = 0

        XCTAssertThrowsError(
            try DeviceIdentityLegacyReconciliation.reconcile(
                legacy,
                with: authority,
                cleanup: {
                    cleanupAttempts += 1
                    throw FakeStoreError.cleanupRefused
                }
            )
        ) { error in
            XCTAssertEqual(error as? FakeStoreError, .cleanupRefused)
        }
        XCTAssertEqual(cleanupAttempts, 1)

        let resolved = try DeviceIdentityLegacyReconciliation.reconcile(
            legacy,
            with: authority,
            cleanup: { cleanupAttempts += 1 }
        )
        XCTAssertEqual(resolved, authority)
        XCTAssertEqual(cleanupAttempts, 2)
    }

    func testAuthorityConflictNeverDeletesLegacyEvidence() throws {
        let authority = makeRecord(deviceId: "cleanup-authority")
        let conflicting = makeRecord(deviceId: "cleanup-conflict")
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
        var cleanupWasCalled = false

        XCTAssertThrowsError(
            try DeviceIdentityLegacyReconciliation.reconcile(
                legacy,
                with: authority,
                cleanup: { cleanupWasCalled = true }
            )
        ) { error in
            XCTAssertEqual(
                error as? DeviceIdentityAuthorityError,
                .legacyIdentityConflictsWithAuthority
            )
        }
        XCTAssertFalse(cleanupWasCalled)
    }

    func testLegacyMigrationRequiresEveryNamespaceToDescribeOneIdentity() throws {
        let candidate = makeRecord(
            deviceId: "one-legacy-identity",
            createdAt: Date(timeIntervalSince1970: 1_675_000_000)
        )
        let keyInfo = legacyKeyInfo(from: candidate)
        let metadata = DeviceIdentityPrivateKeyMetadata(
            publicKey: candidate.publicKey,
            isSecureEnclave: false
        )
        let consistent = DeviceIdentityLegacyState(
            keyInfos: [keyInfo, keyInfo],
            deviceIds: [candidate.deviceId, candidate.deviceId],
            privateKeyMetadata: [metadata, metadata]
        )

        XCTAssertEqual(
            try DeviceIdentityLegacyReconciliation.migrationKeyInfo(
                from: consistent
            ),
            keyInfo
        )

        let other = makeRecord(deviceId: "other-legacy-identity")
        let conflicting = DeviceIdentityLegacyState(
            keyInfos: [keyInfo, legacyKeyInfo(from: other)],
            deviceIds: [candidate.deviceId, other.deviceId],
            privateKeyMetadata: [
                metadata,
                DeviceIdentityPrivateKeyMetadata(
                    publicKey: other.publicKey,
                    isSecureEnclave: false
                )
            ]
        )
        XCTAssertThrowsError(
            try DeviceIdentityLegacyReconciliation.migrationKeyInfo(
                from: conflicting
            )
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
