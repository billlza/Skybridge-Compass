import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
@MainActor
final class PairingIdentityExchangeCommitCoordinatorTests: XCTestCase {
    private let trust = TrustSyncService.shared
    private let kemStore = PeerKEMBootstrapStore.shared
    private var cleanupDeviceIds: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        let liveEntryCount = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(liveEntryCount, 0)
        trust.setInMemoryPersistenceForTesting(true)
        trust.mutationPostSignBarrierForTesting = nil
        await kemStore.clearForTesting()
    }

    override func tearDown() async throws {
        trust.mutationPostSignBarrierForTesting = nil
        if !cleanupDeviceIds.isEmpty {
            try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)
        }
        cleanupDeviceIds.removeAll(keepingCapacity: false)
        await kemStore.clearForTesting()
        let liveEntryCount = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(liveEntryCount, 0)
        trust.setInMemoryPersistenceForTesting(false)
        try await super.tearDown()
    }

    func testNewReservationSupersedesSuspendedCommitWithoutOldRollbackDeletingSuccessor() async throws {
        let deviceId = uniqueDeviceId("overlap")
        cleanupDeviceIds = [deviceId]
        try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)

        let oldIdentity = makeIdentity(seed: 0x11)
        let replacementIdentity = makeIdentity(seed: 0x22)
        let oldPayload = makePayload(
            deviceId: deviceId,
            identity: oldIdentity,
            kemByte: 0x31
        )
        let replacementPayload = makePayload(
            deviceId: deviceId,
            identity: replacementIdentity,
            kemByte: 0x42
        )
        let oldReservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [deviceId]
        )
        let blocker = PairingCommitTestBlocker()
        trust.mutationPostSignBarrierForTesting = {
            await blocker.block()
        }

        let oldTask = Task { @MainActor in
            try await PairingIdentityExchangeCommitCoordinator.commitAuthorityAndKEM(
                reservation: oldReservation,
                payload: oldPayload,
                authority: oldIdentity.authority,
                displayName: "Old pairing operation",
                isCurrent: { true }
            )
        }
        await blocker.waitUntilEntered()

        let replacementReservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [deviceId]
        )
        let replacementTask = Task { @MainActor in
            try await PairingIdentityExchangeCommitCoordinator.commitAuthorityAndKEM(
                reservation: replacementReservation,
                payload: replacementPayload,
                authority: replacementIdentity.authority,
                displayName: "Replacement pairing operation",
                isCurrent: { true }
            )
        }
        await blocker.release()

        do {
            _ = try await oldTask.value
            XCTFail("The suspended old generation must not commit after a replacement reservation")
        } catch let error as TrustSyncError {
            guard case .pairingAuthorityCommitSuperseded = error else {
                return XCTFail("Unexpected old-generation error: \(error)")
            }
        }

        let replacementResult = try await replacementTask.value
        let replacementReceipt = try committedReceipt(from: replacementResult)
        let replacementIsCurrent = await PairingIdentityExchangeCommitCoordinator.isCurrent(
            replacementReceipt,
            transportIsCurrent: { true }
        )
        XCTAssertTrue(replacementIsCurrent)

        let storedReplacementKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [deviceId],
            pinnedProtocolFingerprints: [replacementIdentity.authority.protocolPublicKeyFingerprint]
        )
        let staleOldKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [deviceId],
            pinnedProtocolFingerprints: [oldIdentity.authority.protocolPublicKeyFingerprint]
        )
        XCTAssertEqual(
            storedReplacementKEM[CryptoSuite.mlkem768MLDSA65.wireId],
            Data(repeating: 0x42, count: 1_184)
        )
        XCTAssertTrue(staleOldKEM.isEmpty)

        let storedAuthorityValue = await trust.rawTrustRecordForTesting(deviceId: deviceId)
        let storedAuthority = try XCTUnwrap(storedAuthorityValue)
        XCTAssertEqual(
            storedAuthority.authenticatedProtocolIdentityBinding(for: .ed25519)?.fingerprint,
            replacementIdentity.authority.protocolPublicKeyFingerprint
        )
        _ = await PairingIdentityExchangeCommitCoordinator.rollback(replacementReservation)
    }

    func testCancellationAfterKEMStagingRollsBackBeforeAuthorityCommit() async throws {
        let deviceId = uniqueDeviceId("cancel")
        cleanupDeviceIds = [deviceId]
        try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)

        let identity = makeIdentity(seed: 0x51)
        let payload = makePayload(deviceId: deviceId, identity: identity, kemByte: 0x61)
        let reservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [deviceId]
        )
        let blocker = PairingCommitTestBlocker()
        trust.mutationPostSignBarrierForTesting = {
            await blocker.block()
        }

        let task = Task { @MainActor in
            try await PairingIdentityExchangeCommitCoordinator.commitAuthorityAndKEM(
                reservation: reservation,
                payload: payload,
                authority: identity.authority,
                displayName: "Cancelled pairing operation",
                isCurrent: { true }
            )
        }
        await blocker.waitUntilEntered()
        task.cancel()
        await blocker.release()

        do {
            _ = try await task.value
            XCTFail("Cancellation after staging must fail before the authority commit point")
        } catch is CancellationError {
            // Expected.
        }

        let storedAuthority = await trust.rawTrustRecordForTesting(deviceId: deviceId)
        let storedKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [deviceId],
            pinnedProtocolFingerprints: [identity.authority.protocolPublicKeyFingerprint]
        )
        XCTAssertNil(storedAuthority)
        XCTAssertTrue(storedKEM.isEmpty)
        _ = await PairingIdentityExchangeCommitCoordinator.rollback(reservation)
    }

    func testFailedSuccessorReservationDoesNotReviveOldCommittedGeneration() async throws {
        let deviceId = uniqueDeviceId("aba")
        cleanupDeviceIds = [deviceId]
        try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)

        let identity = makeIdentity(seed: 0x71)
        let payload = makePayload(deviceId: deviceId, identity: identity, kemByte: 0x72)
        let oldReservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [deviceId]
        )
        let oldResult = try await PairingIdentityExchangeCommitCoordinator.commitAuthorityAndKEM(
            reservation: oldReservation,
            payload: payload,
            authority: identity.authority,
            displayName: "Committed generation",
            isCurrent: { true }
        )
        let oldReceipt = try committedReceipt(from: oldResult)
        let oldWasCurrent = await PairingIdentityExchangeCommitCoordinator.isCurrent(
            oldReceipt,
            transportIsCurrent: { true }
        )
        XCTAssertTrue(oldWasCurrent)

        let failedSuccessor = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [deviceId]
        )
        let successorWasRetired = await PairingIdentityExchangeCommitCoordinator.rollback(
            failedSuccessor
        )
        let oldIsCurrentAfterSuccessorRollback = await PairingIdentityExchangeCommitCoordinator
            .isCurrent(oldReceipt, transportIsCurrent: { true })

        XCTAssertTrue(successorWasRetired)
        XCTAssertFalse(
            oldIsCurrentAfterSuccessorRollback,
            "Retiring a failed successor must not restore an older generation (ABA)"
        )
        _ = await PairingIdentityExchangeCommitCoordinator.rollback(oldReservation)
    }

    func testPartiallyOverlappingSuccessorPreservesReplacementAndReleasesOldDisjointAlias() async throws {
        let oldPrimaryId = uniqueDeviceId("partial-old")
        let sharedId = uniqueDeviceId("partial-shared")
        let replacementPrimaryId = uniqueDeviceId("partial-new")
        cleanupDeviceIds = [oldPrimaryId, sharedId, replacementPrimaryId]
        try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)

        let oldIdentity = makeIdentity(seed: 0x81)
        let replacementIdentity = makeIdentity(seed: 0x91)
        let oldPayload = makePayload(
            deviceId: oldPrimaryId,
            identity: oldIdentity,
            kemByte: 0x82
        )
        let replacementPayload = makePayload(
            deviceId: replacementPrimaryId,
            identity: replacementIdentity,
            kemByte: 0x92
        )
        let oldReservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [oldPrimaryId, sharedId]
        )
        let blocker = PairingCommitTestBlocker()
        trust.mutationPostSignBarrierForTesting = {
            await blocker.block()
        }
        let oldTask = Task { @MainActor in
            try await PairingIdentityExchangeCommitCoordinator.commitAuthorityAndKEM(
                reservation: oldReservation,
                payload: oldPayload,
                authority: oldIdentity.authority,
                displayName: "Partially overlapping old operation",
                isCurrent: { true }
            )
        }
        await blocker.waitUntilEntered()

        let replacementReservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [sharedId, replacementPrimaryId]
        )
        let replacementTask = Task { @MainActor in
            try await PairingIdentityExchangeCommitCoordinator.commitAuthorityAndKEM(
                reservation: replacementReservation,
                payload: replacementPayload,
                authority: replacementIdentity.authority,
                displayName: "Partially overlapping replacement",
                isCurrent: { true }
            )
        }
        await blocker.release()

        do {
            _ = try await oldTask.value
            XCTFail("The partially-overlapped old generation must be superseded")
        } catch let error as TrustSyncError {
            guard case .pairingAuthorityCommitSuperseded = error else {
                return XCTFail("Unexpected partial-overlap error: \(error)")
            }
        }
        let replacementResult = try await replacementTask.value
        _ = try committedReceipt(from: replacementResult)

        let oldDisjointKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [oldPrimaryId],
            pinnedProtocolFingerprints: [oldIdentity.authority.protocolPublicKeyFingerprint]
        )
        let sharedReplacementKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [sharedId],
            pinnedProtocolFingerprints: [replacementIdentity.authority.protocolPublicKeyFingerprint]
        )
        let replacementPrimaryKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [replacementPrimaryId],
            pinnedProtocolFingerprints: [replacementIdentity.authority.protocolPublicKeyFingerprint]
        )
        XCTAssertTrue(oldDisjointKEM.isEmpty)
        XCTAssertEqual(
            sharedReplacementKEM[CryptoSuite.mlkem768MLDSA65.wireId],
            Data(repeating: 0x92, count: 1_184)
        )
        XCTAssertEqual(
            replacementPrimaryKEM[CryptoSuite.mlkem768MLDSA65.wireId],
            Data(repeating: 0x92, count: 1_184)
        )
        _ = await PairingIdentityExchangeCommitCoordinator.rollback(replacementReservation)
    }

    func testCommittedScopeAlwaysFinishesWithoutRollingBackDurableAuthorityOrKEM() async throws {
        let deviceId = uniqueDeviceId("finish")
        cleanupDeviceIds = [deviceId]
        try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)
        let identity = makeIdentity(seed: 0xA1)
        let payload = makePayload(deviceId: deviceId, identity: identity, kemByte: 0xA2)
        let reservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [deviceId]
        )
        let result = try await PairingIdentityExchangeCommitCoordinator.commitAuthorityAndKEM(
            reservation: reservation,
            payload: payload,
            authority: identity.authority,
            displayName: "Finished pairing operation",
            isCurrent: { true }
        )
        let receipt = try committedReceipt(from: result)

        enum ExpectedFailure: Error { case stop }
        do {
            try await PairingIdentityExchangeCommitCoordinator.withMainActorCommittedReceipt(receipt) {
                throw ExpectedFailure.stop
            }
            XCTFail("Expected the committed side-effect scope to throw")
        } catch ExpectedFailure.stop {
            // Expected.
        }

        let receiptIsCurrent = await PairingIdentityExchangeCommitCoordinator.isCurrent(
            receipt,
            transportIsCurrent: { true }
        )
        XCTAssertFalse(receiptIsCurrent)
        let liveEntryCount = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(liveEntryCount, 0)
        let persistedAuthority = await trust.rawTrustRecordForTesting(deviceId: deviceId)
        XCTAssertNotNil(persistedAuthority)
        let persistedKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [deviceId],
            pinnedProtocolFingerprints: [identity.authority.protocolPublicKeyFingerprint]
        )
        XCTAssertEqual(
            persistedKEM[CryptoSuite.mlkem768MLDSA65.wireId],
            Data(repeating: 0xA2, count: 1_184)
        )
        let duplicateFinish = await PairingIdentityExchangeCommitCoordinator.finish(receipt)
        XCTAssertFalse(duplicateFinish)
    }

    func testReservationLimitsAreAtomicAndOverlappingSuccessorDoesNotConsumeCapacity() async throws {
        let tooManyIds = (0..<9).map { uniqueDeviceId("too-many-\($0)") }
        do {
            _ = try await PairingIdentityExchangeCommitCoordinator.reserve(deviceIds: tooManyIds)
            XCTFail("More than eight stable identifiers must be rejected")
        } catch let error as PairingIdentityExchangeCommitCoordinator.CommitError {
            guard case .tooManyStableDeviceIdentifiers(maximum: 8) = error else {
                return XCTFail("Unexpected identifier limit error: \(error)")
            }
        }
        var liveEntryCount = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(liveEntryCount, 0)

        var reservations: [PairingIdentityExchangeCommitCoordinator.Reservation] = []
        var firstCapacityDeviceId: String?
        for group in 0..<8 {
            // Each raw identifier produces a persisted `id:` alias and its
            // unprefixed lookup candidate, so four inputs fill eight entries.
            let ids = (0..<4).map { uniqueDeviceId("capacity-\(group)-\($0)") }
            if firstCapacityDeviceId == nil {
                firstCapacityDeviceId = ids[0]
            }
            reservations.append(
                try await PairingIdentityExchangeCommitCoordinator.reserve(deviceIds: ids)
            )
        }
        liveEntryCount = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(liveEntryCount, 64)
        let overlapping = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [try XCTUnwrap(firstCapacityDeviceId)]
        )
        liveEntryCount = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(liveEntryCount, 64)
        do {
            _ = try await PairingIdentityExchangeCommitCoordinator.reserve(
                deviceIds: [uniqueDeviceId("capacity-overflow")]
            )
            XCTFail("A sixty-fifth live identifier must be rejected atomically")
        } catch let error as PairingIdentityExchangeCommitCoordinator.CommitError {
            guard case .reservationCapacityExceeded(maximum: 64) = error else {
                return XCTFail("Unexpected capacity error: \(error)")
            }
        }
        liveEntryCount = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(liveEntryCount, 64)
        for reservation in reservations {
            _ = await PairingIdentityExchangeCommitCoordinator.rollback(reservation)
        }
        _ = await PairingIdentityExchangeCommitCoordinator.rollback(overlapping)
    }

    func testAlreadyCancelledCommittedScopeSkipsEffectsAndFinishesLease() async throws {
        let deviceId = uniqueDeviceId("cancelled-scope")
        cleanupDeviceIds = [deviceId]
        try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)
        let identity = makeIdentity(seed: 0xB1)
        let payload = makePayload(deviceId: deviceId, identity: identity, kemByte: 0xB2)
        let reservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [deviceId]
        )
        let result = try await PairingIdentityExchangeCommitCoordinator.commitAuthorityAndKEM(
            reservation: reservation,
            payload: payload,
            authority: identity.authority,
            displayName: "Cancelled committed scope",
            isCurrent: { true }
        )
        let receipt = try committedReceipt(from: result)
        let probe = PairingCommitEffectProbe()
        let task = Task { @MainActor in
            try await PairingIdentityExchangeCommitCoordinator.withMainActorCommittedReceipt(receipt) {
                await probe.markCalled()
            }
        }
        task.cancel()
        do {
            try await task.value
            XCTFail("An already-cancelled committed scope must not begin side effects")
        } catch is CancellationError {
            // Expected.
        }
        let effectWasCalled = await probe.wasCalled()
        XCTAssertFalse(effectWasCalled)
        let liveEntryCount = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(liveEntryCount, 0)
        let persistedTrust = await trust.rawTrustRecordForTesting(deviceId: deviceId)
        XCTAssertNotNil(persistedTrust)
        let persistedKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [deviceId],
            pinnedProtocolFingerprints: [identity.authority.protocolPublicKeyFingerprint]
        )
        XCTAssertFalse(persistedKEM.isEmpty)
    }

    func testCommittedScopeEarlyReturnAndInScopeCancellationFinishLease() async throws {
        let earlyReturnDeviceId = uniqueDeviceId("early-return")
        let cancelledDeviceId = uniqueDeviceId("in-scope-cancellation")
        cleanupDeviceIds = [earlyReturnDeviceId, cancelledDeviceId]
        try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)

        let earlyIdentity = makeIdentity(seed: 0xC1)
        let earlyReservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [earlyReturnDeviceId]
        )
        let earlyResult = try await PairingIdentityExchangeCommitCoordinator.commitAuthorityAndKEM(
            reservation: earlyReservation,
            payload: makePayload(
                deviceId: earlyReturnDeviceId,
                identity: earlyIdentity,
                kemByte: 0xC2
            ),
            authority: earlyIdentity.authority,
            displayName: "Early-return committed scope",
            isCurrent: { true }
        )
        let earlyReceipt = try committedReceipt(from: earlyResult)
        let operationResult = try await PairingIdentityExchangeCommitCoordinator
            .withMainActorCommittedReceipt(earlyReceipt) {
                false
            }
        XCTAssertFalse(operationResult)
        let countAfterEarlyReturn = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(countAfterEarlyReturn, 0)
        let earlyPersistedTrust = await trust.rawTrustRecordForTesting(
            deviceId: earlyReturnDeviceId
        )
        XCTAssertNotNil(earlyPersistedTrust)

        let cancelledIdentity = makeIdentity(seed: 0xD1)
        let cancelledReservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [cancelledDeviceId]
        )
        let cancelledResult = try await PairingIdentityExchangeCommitCoordinator
            .commitAuthorityAndKEM(
                reservation: cancelledReservation,
                payload: makePayload(
                    deviceId: cancelledDeviceId,
                    identity: cancelledIdentity,
                    kemByte: 0xD2
                ),
                authority: cancelledIdentity.authority,
                displayName: "Cancelled committed scope",
                isCurrent: { true }
            )
        let cancelledReceipt = try committedReceipt(from: cancelledResult)
        do {
            try await PairingIdentityExchangeCommitCoordinator
                .withMainActorCommittedReceipt(cancelledReceipt) {
                    throw CancellationError()
                }
            XCTFail("Cancellation from inside the committed scope must propagate")
        } catch is CancellationError {
            // Expected.
        }
        let countAfterCancellation = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(countAfterCancellation, 0)
        let cancelledPersistedTrust = await trust.rawTrustRecordForTesting(
            deviceId: cancelledDeviceId
        )
        XCTAssertNotNil(cancelledPersistedTrust)
    }

    func testAlreadyCancelledCommitBeforeKEMStagingRetiresReservation() async throws {
        let deviceId = uniqueDeviceId("cancel-before-staging")
        cleanupDeviceIds = [deviceId]
        try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)
        let identity = makeIdentity(seed: 0xE1)
        let payload = makePayload(deviceId: deviceId, identity: identity, kemByte: 0xE2)
        let reservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [deviceId]
        )
        let task = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(60))
            } catch is CancellationError {
                // Continue deliberately so commit observes an already-cancelled task.
            }
            XCTAssertTrue(Task.isCancelled)
            return try await PairingIdentityExchangeCommitCoordinator.commitAuthorityAndKEM(
                reservation: reservation,
                payload: payload,
                authority: identity.authority,
                displayName: "Cancelled before KEM staging",
                isCurrent: { true }
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("An already-cancelled commit must fail before KEM staging")
        } catch is CancellationError {
            // Expected.
        }
        let countAfterCancelledCommit = await PairingIdentityExchangeCommitCoordinator
            .liveReservationDeviceEntryCountForTesting()
        XCTAssertEqual(countAfterCancelledCommit, 0)
        let cancelledCommitTrust = await trust.rawTrustRecordForTesting(deviceId: deviceId)
        XCTAssertNil(cancelledCommitTrust)
        let persistedKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [deviceId],
            pinnedProtocolFingerprints: [identity.authority.protocolPublicKeyFingerprint]
        )
        XCTAssertTrue(persistedKEM.isEmpty)
    }

    func testCaseOnlyCommittedSuccessorReplacesTheSameDurableKEMIdentity() async throws {
        let originalDeviceId = "CaseOnly99"
        let successorDeviceId = originalDeviceId.lowercased()
        cleanupDeviceIds = Array(Set(
            PeerTrustLookup.lookupCandidates(for: originalDeviceId)
                + PeerTrustLookup.lookupCandidates(for: successorDeviceId)
        ))
        try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)

        let originalIdentity = makeIdentity(seed: 0xC1)
        let successorIdentity = makeIdentity(seed: 0xC2)
        let originalReservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [originalDeviceId]
        )
        let originalResult = try await PairingIdentityExchangeCommitCoordinator
            .commitAuthorityAndKEM(
                reservation: originalReservation,
                payload: makePayload(
                    deviceId: originalDeviceId,
                    identity: originalIdentity,
                    kemByte: 0xC3
                ),
                authority: originalIdentity.authority,
                displayName: "Original casing",
                isCurrent: { true }
            )
        let originalReceipt = try committedReceipt(from: originalResult)

        // An authority change for the same signing algorithm is admitted only
        // after an explicit trust removal. Keep the staged KEM state in place
        // so this reproduces the durable case-only orphan that existed across
        // a legitimate forget-and-repair flow.
        try await trust.removeRecordsForTesting(deviceIds: cleanupDeviceIds)

        let successorReservation = try await PairingIdentityExchangeCommitCoordinator.reserve(
            deviceIds: [successorDeviceId]
        )
        let successorResult = try await PairingIdentityExchangeCommitCoordinator
            .commitAuthorityAndKEM(
                reservation: successorReservation,
                payload: makePayload(
                    deviceId: successorDeviceId,
                    identity: successorIdentity,
                    kemByte: 0xC4
                ),
                authority: successorIdentity.authority,
                displayName: "Canonical casing",
                isCurrent: { true }
            )
        let successorReceipt = try committedReceipt(from: successorResult)

        let staleKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [originalDeviceId, successorDeviceId],
            pinnedProtocolFingerprints: [
                originalIdentity.authority.protocolPublicKeyFingerprint
            ]
        )
        let currentKEM = await kemStore.authorityBoundPairingKEMPublicKeys(
            forCandidates: [originalDeviceId, successorDeviceId],
            pinnedProtocolFingerprints: [
                successorIdentity.authority.protocolPublicKeyFingerprint
            ]
        )
        XCTAssertTrue(staleKEM.isEmpty)
        XCTAssertEqual(
            currentKEM[CryptoSuite.mlkem768MLDSA65.wireId],
            Data(repeating: 0xC4, count: 1_184)
        )
        let originalStillCurrent = await PairingIdentityExchangeCommitCoordinator.isCurrent(
            originalReceipt,
            transportIsCurrent: { true }
        )
        let successorIsCurrent = await PairingIdentityExchangeCommitCoordinator.isCurrent(
            successorReceipt,
            transportIsCurrent: { true }
        )
        XCTAssertFalse(originalStillCurrent)
        XCTAssertTrue(successorIsCurrent)

        _ = await PairingIdentityExchangeCommitCoordinator.finish(originalReceipt)
        _ = await PairingIdentityExchangeCommitCoordinator.finish(successorReceipt)
    }

    private func makeIdentity(seed: UInt8) -> (
        publicKey: Data,
        authority: AuthenticatedRemoteAuthority
    ) {
        let publicKey = Data(repeating: seed, count: 32)
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(
            algorithm: .ed25519,
            publicKeyBytes: publicKey
        )
        return (
            publicKey,
            AuthenticatedRemoteAuthority(
                protocolSigningAlgorithm: .ed25519,
                protocolPublicKeyFingerprint: fingerprint,
                protocolPublicKey: publicKey
            )
        )
    }

    private func makePayload(
        deviceId: String,
        identity: (publicKey: Data, authority: AuthenticatedRemoteAuthority),
        kemByte: UInt8
    ) -> AppMessage.PairingIdentityExchangePayload {
        AppMessage.PairingIdentityExchangePayload(
            deviceId: deviceId,
            kemPublicKeys: [
                KEMPublicKeyInfo(
                    suiteWireId: CryptoSuite.mlkem768MLDSA65.wireId,
                    publicKey: Data(repeating: kemByte, count: 1_184)
                )
            ],
            protocolIdentityPublicKeys: [
                .init(
                    protocolSigningAlgorithm: ProtocolSigningAlgorithm.ed25519.rawValue,
                    publicKey: identity.publicKey
                )
            ],
            platform: "macOS",
            osVersion: "26.0"
        )
    }

    private func committedReceipt(
        from result: PairingIdentityExchangeCommitCoordinator.CommitResult
    ) throws -> PairingIdentityExchangeCommitCoordinator.CommitReceipt {
        guard case .committed(let receipt) = result else {
            XCTFail("Expected an admitted pairing generation to commit")
            throw PairingCommitTestError.expectedCommittedResult
        }
        return receipt
    }

    private func uniqueDeviceId(_ label: String) -> String {
        "id:pairing-commit-\(label)-\(UUID().uuidString.lowercased())"
    }
}

private enum PairingCommitTestError: Error {
    case expectedCommittedResult
}

private actor PairingCommitTestBlocker {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func block() async {
        entered = true
        let waiters = entryWaiters
        entryWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters {
            waiter.resume()
        }
        guard !released else { return }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    func release() {
        guard !released else { return }
        released = true
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor PairingCommitEffectProbe {
    private var called = false

    func markCalled() {
        called = true
    }

    func wasCalled() -> Bool {
        called
    }
}
