import XCTest
import Darwin
import os
import Security
import SkyBridgeProtocolCore
@testable import SkyBridgeCompass_iOS

@MainActor
final class IOSAuthenticationSessionStateTests: XCTestCase {
    func testNewLoginSaveFailureRevokesOldAudioWithoutPublishingFailedSession() async throws {
        let disk = AuthenticationTestStorage()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        let a = session("a"), b = session("b")
        try await state.install(a, intent: state.beginMutation())
        let old = try XCTUnwrap(state.audioAuthorization)
        disk.failure = .store
        let replacement = state.beginMutation()
        XCTAssertFalse(old.isCurrent)
        do { try await state.install(b, intent: replacement); XCTFail("Save failure hidden") }
        catch { XCTAssertEqual(error as? AuthenticationStorageFailure, .store) }
        XCTAssertEqual(state.session, a); XCTAssertEqual(try disk.value, a)
        XCTAssertNil(state.audioAuthorization)
    }

    func testFailedLogoutDeleteCannotRestoreAudioAuthority() async throws {
        let disk = AuthenticationTestStorage()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        let a = session("a")
        try await state.install(a, intent: state.beginMutation())
        let old = try XCTUnwrap(state.audioAuthorization)
        disk.failure = .delete
        do { try await state.clear(intent: state.beginMutation()); XCTFail("Delete failure hidden") }
        catch { XCTAssertEqual(error as? AuthenticationStorageFailure, .delete) }
        XCTAssertFalse(old.isCurrent); XCTAssertNil(state.audioAuthorization)
        XCTAssertEqual(state.session, a); XCTAssertEqual(try disk.value, a)
    }

    func testSameAccountSameValueLoginCreatesNewEpochAndRejectsOldWitness() async throws {
        let disk = AuthenticationTestStorage(), a = session("a")
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(a, intent: state.beginMutation())
        let old = try state.witness(), oldAudio = try XCTUnwrap(state.audioAuthorization)
        try await state.install(a, intent: state.beginMutation())
        XCTAssertFalse(oldAudio.isCurrent)
        XCTAssertFalse(state.audioAuthorization === oldAudio)
        do { try await state.replace(session("a", token: "late"), expected: old); XCTFail("ABA accepted") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
        XCTAssertEqual(try disk.value, a); XCTAssertEqual(state.session, a)
    }

    func testLateLoginWaitingBeforeActualWriteCannotOverwriteNewLogin() async throws {
        let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        let a = session("a"), b = session("b")
        disk.beforeStore = barrier
        let intent = state.beginMutation()
        let old = Task { try await state.install(a, intent: intent) }
        try await barrier.waitForArrival()
        disk.beforeStore = nil
        try await state.install(b, intent: state.beginMutation())
        barrier.release()
        do { try await old.value; XCTFail("Old login committed") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
        XCTAssertEqual(try disk.value, b); XCTAssertEqual(state.session, b)
    }

    func testLateLoginReturningAfterActualWriteCannotPublishOverNewLogin() async throws {
        let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        disk.afterStore = barrier
        let oldIntent = state.beginMutation()
        let old = Task { try await state.install(self.session("a"), intent: oldIntent) }
        try await barrier.waitForArrival()
        XCTAssertNil(state.session); XCTAssertNotNil(try disk.value)
        disk.afterStore = nil
        let b = session("b")
        try await state.install(b, intent: state.beginMutation())
        let currentAudio = state.audioAuthorization
        barrier.release()
        do { try await old.value; XCTFail("Old publication accepted") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
        XCTAssertEqual(state.session, b); XCTAssertEqual(try disk.value, b)
        XCTAssertTrue(state.audioAuthorization === currentAudio)
    }

    func testLateLogoutCannotDeleteReplacementLogin() async throws {
        let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("a"), intent: state.beginMutation())
        disk.beforeDelete = barrier
        let intent = state.beginMutation()
        let logout = Task { try await state.clear(intent: intent) }
        try await barrier.waitForArrival()
        let b = session("b")
        try await state.install(b, intent: state.beginMutation())
        barrier.release()
        do { try await logout.value; XCTFail("Late logout deleted B") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
        XCTAssertEqual(state.session, b); XCTAssertEqual(try disk.value, b)
    }

    func testLateRestoreSuccessAndFailureCannotReplaceNewSession() async throws {
        for fail in [false, true] {
            let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
            try disk.seedSession(session("a")); disk.beforeLoadReturn = barrier
            if fail { disk.failure = .load }
            let state = IOSAuthenticationSessionState(storage: disk.dependencies)
            let intent = state.currentIntent
            let restore = Task { try await state.restore(intent: intent) }
            try await barrier.waitForArrival()
            let b = session("b")
            try await state.install(b, intent: state.beginMutation())
            let current = state.audioAuthorization
            barrier.release()
            do { _ = try await restore.value; XCTFail("Late restore accepted") }
            catch {
                if fail { XCTAssertEqual(error as? AuthenticationStorageFailure, .load) }
                else { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
            }
            XCTAssertEqual(state.session, b); XCTAssertTrue(state.audioAuthorization === current)
        }
    }

    func testProfileCASCannotRollBackAnAlreadyRotatedPersistedToken() async throws {
        let disk = AuthenticationTestStorage()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        let a = session("a")
        try await state.install(a, intent: state.beginMutation())
        let old = try state.witness()
        let rotated = session("a", token: "rotated")
        try disk.seedSession(rotated)
        do { try await state.replace(session("a", name: "late profile"), expected: old); XCTFail("Old token restored") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
        XCTAssertEqual(try disk.value, rotated)
        XCTAssertEqual(state.session, a, "A failed CAS must not falsely publish success")
    }

    func testValidatedRefreshAndProfilePreserveEpochButRetireOldRevision() async throws {
        let disk = AuthenticationTestStorage()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("a"), intent: state.beginMutation())
        let epoch = try XCTUnwrap(state.audioAuthorization), old = try state.witness()
        try await state.replace(session("a", token: "rotated"), expected: old)
        XCTAssertTrue(epoch.isCurrent); XCTAssertTrue(state.audioAuthorization === epoch)
        XCTAssertThrowsError(try state.requireCurrent(old))
        let refreshed = try state.witness()
        let profile = session("a", token: "rotated", name: "profile")
        try await state.replace(profile, expected: refreshed)
        XCTAssertEqual(try disk.value, profile); XCTAssertEqual(state.session, profile)
        XCTAssertTrue(state.audioAuthorization === epoch)
    }

    func testLateHardRejectionCannotRevokeNewLoginOrNewRefreshRevision() async throws {
        let disk = AuthenticationTestStorage()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("a"), intent: state.beginMutation())
        let old = try state.witness()
        try await state.install(session("a"), intent: state.beginMutation())
        let current = try XCTUnwrap(state.audioAuthorization)
        try await state.revokeAudio(expected: old)
        XCTAssertTrue(current.isCurrent)
        let beforeRefresh = try state.witness()
        try await state.replace(session("a", token: "rotated"), expected: beforeRefresh)
        try await state.revokeAudio(expected: beforeRefresh)
        XCTAssertTrue(current.isCurrent)
        try await state.revokeAudio(expected: try state.witness())
        XCTAssertFalse(current.isCurrent); XCTAssertNil(state.audioAuthorization)
    }

    func testRestoreComparisonFailureNeverPublishesAudioEpoch() async throws {
        let disk = AuthenticationTestStorage()
        try disk.seedSession(session("b"))
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        do { _ = try await state.restore(intent: state.currentIntent, matching: session("a")); XCTFail("Mismatch published") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
        XCTAssertNil(state.session); XCTAssertNil(state.audioAuthorization)
    }

    func testRevokedIntentRejectsAllActualKeychainMutationEntryPoints() async throws {
        let intent = IOSAuthenticationIntent(); intent.invalidate()
        let a = session("a")
        do { try await KeychainManager.shared.storeAuthSession(a, intent: intent); XCTFail("Revoked store ran") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
        do { _ = try await KeychainManager.shared.replaceAuthSession(expected: a, expectedLoginID: UUID(), with: a, intent: intent); XCTFail("Revoked CAS ran") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
        do { try await KeychainManager.shared.deleteAuthSession(intent: intent); XCTFail("Revoked delete ran") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
    }

    func testConcurrentNoopProfileAndRefreshCannotSplitDiskAndPublication() async throws {
        let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        let a = session("a"), rotated = session("a", token: "rotated")
        try await state.install(a, intent: state.beginMutation())
        let expected = try state.witness()
        disk.afterReplace = barrier
        let profile = Task { try await state.replace(a, expected: expected) }
        try await barrier.waitForArrival()
        do { try await state.replace(rotated, expected: expected); XCTFail("Concurrent publication admitted") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .publicationInProgress) }
        XCTAssertEqual(try disk.value, a)
        barrier.release()
        try await profile.value
        disk.afterReplace = nil
        try await state.replace(rotated, expected: state.witness(matchingCredentials: expected))
        XCTAssertEqual(try disk.value, rotated); XCTAssertEqual(state.session, rotated)
    }

    func testProfileUpdateCannotHideHardRejectionOfUnchangedCredentials() async throws {
        let disk = AuthenticationTestStorage()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("a"), intent: state.beginMutation())
        let request = try state.witness(), epoch = try XCTUnwrap(state.audioAuthorization)
        try await state.replace(session("a", name: "new profile"), expected: request)
        XCTAssertEqual(try state.witness(matchingCredentials: request).session.displayName, "new profile")
        try await state.revokeAudio(expected: request)
        XCTAssertFalse(epoch.isCurrent); XCTAssertNil(state.audioAuthorization)
    }

    func testRefreshReservesPublicationBeforeHTTPAndPreservesReturnedToken() async throws {
        let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("a"), intent: state.beginMutation())
        let expected = try state.witness(), rotated = session("a", token: "rotated")
        let refresh = Task {
            try await state.refresh(expected: expected) { _ in
                await barrier.wait()
                return rotated
            }
        }
        try await barrier.waitForArrival()
        do { try await state.replace(session("a", name: "late profile"), expected: expected); XCTFail("Profile entered refresh publication") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .publicationInProgress) }
        barrier.release()
        let result = try await refresh.value
        XCTAssertEqual(result, rotated); XCTAssertEqual(try disk.value, rotated); XCTAssertEqual(state.session, rotated)
        XCTAssertTrue(state.audioAuthorization === expected.audioAuthorization)
    }

    func testBusyPublicationRejectsRefreshBeforeRemoteTokenRotation() async throws {
        let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        let a = session("a")
        try await state.install(a, intent: state.beginMutation())
        let expected = try state.witness()
        disk.afterReplace = barrier
        let profile = Task { try await state.replace(a, expected: expected) }
        try await barrier.waitForArrival()
        var requests = 0
        do {
            _ = try await state.refresh(expected: expected) { _ in requests += 1; return self.session("a", token: "rotated") }
            XCTFail("Refresh admitted during publication")
        } catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .publicationInProgress) }
        XCTAssertEqual(requests, 0)
        barrier.release(); try await profile.value
        XCTAssertEqual(try disk.value, a); XCTAssertEqual(state.session, a)
    }

    func testLateRefreshAfterReplacementCannotWriteOrReauthorize() async throws {
        let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("a"), intent: state.beginMutation())
        let expected = try state.witness()
        let refresh = Task {
            try await state.refresh(expected: expected) { _ in
                await barrier.wait()
                return self.session("a", token: "rotated")
            }
        }
        try await barrier.waitForArrival()
        let b = session("b")
        try await state.install(b, intent: state.beginMutation())
        let current = state.audioAuthorization
        barrier.release()
        do { _ = try await refresh.value; XCTFail("Old refresh published") }
        catch { XCTAssertEqual(error as? IOSAuthenticationSessionError, .changed) }
        XCTAssertEqual(try disk.value, b); XCTAssertEqual(state.session, b)
        XCTAssertTrue(state.audioAuthorization === current)
    }

    func testFreshOwnerRestoresOriginalDurableLoginIdentifier() async throws {
        let disk = AuthenticationTestStorage()
        let first = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await first.install(session("restart"), intent: first.beginMutation())
        let loginID = try XCTUnwrap(first.audioAuthorization).loginID
        let restored = IOSAuthenticationSessionState(storage: disk.dependencies)
        _ = try await restored.restore(intent: restored.currentIntent)
        XCTAssertEqual(restored.audioAuthorization?.loginID, loginID)
    }

    func testFreshOwnerCannotRestoreRejectedAudioAuthorization() async throws {
        let disk = AuthenticationTestStorage()
        let first = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await first.install(session("rejected"), intent: first.beginMutation())
        try await first.revokeAudio(expected: try first.witness())
        let restored = IOSAuthenticationSessionState(storage: disk.dependencies)
        _ = try await restored.restore(intent: restored.currentIntent)
        XCTAssertNil(restored.audioAuthorization)
    }

    func testRefreshPreparationFailurePreventsHTTP() async throws {
        let disk = AuthenticationTestStorage(), state = IOSAuthenticationSessionState(storage: .live(keychain: disk.keychain))
        try await state.install(session("prepare"), intent: state.beginMutation())
        disk.native.state.withLock { $0.failNextWrite = true }
        var requests = 0
        do {
            _ = try await state.refresh(expected: state.witness()) { _ in requests += 1; return self.session("prepare", token: "new") }
            XCTFail("Preparation failure hidden")
        } catch { XCTAssertEqual(error as? AuthenticationStorageFailure, .write) }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(try disk.root.load()?.observations, [])
    }

    func testUncommittedRefreshCannotRestoreAudioInFreshNativeOwner() async throws {
        let disk = AuthenticationTestStorage(), state = IOSAuthenticationSessionState(storage: .live(keychain: disk.keychain))
        let original = session("commit")
        try await state.install(original, intent: state.beginMutation())
        do {
            _ = try await state.refresh(expected: state.witness()) { _ in
                XCTAssertEqual(try disk.root.load()?.observations.count, 1, "Marker precedes HTTP")
                disk.native.state.withLock { $0.failNextWrite = true }
                return self.session("commit", token: "rotated")
            }
            XCTFail("Commit failure hidden")
        } catch { XCTAssertEqual(error as? AuthenticationStorageFailure, .write) }
        let restored = IOSAuthenticationSessionState(storage: .live(keychain: disk.newKeychainOwner()))
        let loaded = try await restored.restore(intent: restored.currentIntent)
        XCTAssertEqual(loaded, original)
        XCTAssertNil(restored.audioAuthorization)
        XCTAssertTrue(restored.needsCredentialVerification)
        XCTAssertEqual(try disk.root.load()?.observations.count, 1)
    }

    func testKnownTemporaryFailureSettlesOwnedObservationWithoutNewLogin() async throws {
        let disk = AuthenticationTestStorage(), state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("temporary"), intent: state.beginMutation())
        let loginID = try state.witness().loginID
        do {
            _ = try await state.refresh(expected: state.witness()) { _ in throw URLError(.notConnectedToInternet) }
            XCTFail("Network failure hidden")
        } catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        let restored = IOSAuthenticationSessionState(storage: .live(keychain: disk.newKeychainOwner()))
        _ = try await restored.restore(intent: restored.currentIntent)
        XCTAssertEqual(restored.audioAuthorization?.loginID, loginID)
        XCTAssertFalse(restored.needsCredentialVerification)
        XCTAssertEqual(try disk.root.load()?.observations, [])
    }

    func testTemporaryFailureCannotSettleUnknownPredecessorButValidatedRefreshCan() async throws {
        let disk = AuthenticationTestStorage(), source = session("orphan")
        try disk.seedSession(source)
        let oldRecord = try XCTUnwrap(disk.root.load()), loginID = try XCTUnwrap(oldRecord.loginID)
        _ = try disk.root.beginObservation(ProtectedAccountObservation(kind: .credential), owned: [], replacing: oldRecord)
        let restored = IOSAuthenticationSessionState(storage: .live(keychain: disk.newKeychainOwner()))
        _ = try await restored.restore(intent: restored.currentIntent)
        XCTAssertNil(restored.audioAuthorization)
        do {
            _ = try await restored.refresh(expected: restored.witness()) { _ in throw URLError(.timedOut) }
            XCTFail("Timeout hidden")
        } catch { XCTAssertEqual((error as? URLError)?.code, .timedOut) }
        XCTAssertTrue(restored.needsCredentialVerification)
        XCTAssertTrue(try XCTUnwrap(disk.root.load()).requiresCredentialVerification)
        let replacement = session("orphan", token: "verified")
        _ = try await restored.refresh(expected: restored.witness()) { _ in replacement }
        XCTAssertFalse(restored.needsCredentialVerification)
        XCTAssertEqual(restored.audioAuthorization?.loginID, loginID)
        XCTAssertEqual(try disk.root.load()?.observations, [])
    }

    func testRejectedRefreshAndFailedRevocationWriteStillDenyFreshOwner() async throws {
        let disk = AuthenticationTestStorage(), state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("deny"), intent: state.beginMutation())
        let expected = try state.witness(), old = try XCTUnwrap(state.audioAuthorization)
        do {
            _ = try await state.refresh(expected: expected) { _ in
                disk.native.state.withLock { $0.failNextWrite = true }
                try await state.revokeAudio(expected: expected)
                throw IOSAuthenticationSessionError.changed
            }
            XCTFail("Failure hidden")
        } catch { XCTAssertEqual(error as? AuthenticationStorageFailure, .write) }
        XCTAssertFalse(old.isCurrent)
        let restored = IOSAuthenticationSessionState(storage: .live(keychain: disk.newKeychainOwner()))
        _ = try await restored.restore(intent: restored.currentIntent)
        XCTAssertNil(restored.audioAuthorization)
        XCTAssertTrue(restored.needsCredentialVerification)
    }

    func testTemporaryRequestAndSettlementFailuresBothRemainObservable() async throws {
        let disk = AuthenticationTestStorage(), state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("settlement"), intent: state.beginMutation())
        do {
            _ = try await state.refresh(expected: state.witness()) { _ in
                disk.native.state.withLock { $0.failNextWrite = true }
                throw URLError(.timedOut)
            }
            XCTFail("Combined failure hidden")
        } catch let failure as IOSAuthenticationPersistenceFailure {
            XCTAssertEqual((failure.original as? URLError)?.code, .timedOut)
            XCTAssertEqual(failure.persistence as? AuthenticationStorageFailure, .write)
        }
        let restored = IOSAuthenticationSessionState(storage: .live(keychain: disk.newKeychainOwner()))
        _ = try await restored.restore(intent: restored.currentIntent)
        XCTAssertNil(restored.audioAuthorization)
        XCTAssertTrue(restored.needsCredentialVerification)
    }

    func testValidatedRefreshDoesNotUndoDurableAudioRevocation() async throws {
        let disk = AuthenticationTestStorage(), state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("revoked"), intent: state.beginMutation())
        try await state.revokeAudio(expected: state.witness())
        let restored = IOSAuthenticationSessionState(storage: .live(keychain: disk.newKeychainOwner()))
        _ = try await restored.restore(intent: restored.currentIntent)
        _ = try await restored.refresh(expected: restored.witness()) { _ in self.session("revoked", token: "new") }
        XCTAssertNil(restored.audioAuthorization)
        XCTAssertTrue(try XCTUnwrap(disk.root.load()).audioRevoked)
    }

    func testTombstonePreventsLegacyResurrectionEvenWhenCleanupInitiallyFails() async throws {
        let disk = AuthenticationTestStorage(), state = IOSAuthenticationSessionState(storage: disk.dependencies)
        let original = session("logout")
        try await state.install(original, intent: state.beginMutation())
        let bytes = try JSONEncoder().encode(original)
        disk.native.state.withLock { $0.legacy = bytes; $0.failLegacyCleanup = true }
        do { try await state.clear(intent: state.beginMutation()); XCTFail("Cleanup failure hidden") }
        catch { XCTAssertEqual(error as? AuthenticationStorageFailure, .legacyCleanup) }
        XCTAssertNil(try disk.root.load()?.session)
        let loads = disk.native.state.withLock { $0.legacyLoads }
        disk.native.state.withLock { $0.failLegacyCleanup = false }
        let restored = IOSAuthenticationSessionState(storage: .live(keychain: disk.newKeychainOwner()))
        let loaded = try await restored.restore(intent: restored.currentIntent)
        XCTAssertNil(loaded); XCTAssertNil(restored.audioAuthorization)
        XCTAssertEqual(disk.native.state.withLock { $0.legacyLoads }, loads)
        XCTAssertNil(disk.native.state.withLock { $0.legacy })
    }

    func testSameCredentialsInNewLoginRejectOldNativeOwnerAndObservation() async throws {
        let disk = AuthenticationTestStorage(), source = session("aba")
        let first = try await disk.keychain.storeAuthSession(source)
        let firstID = try XCTUnwrap(first.loginID), intent = IOSAuthenticationIntent()
        let ticket = try await disk.keychain.beginAccountObservation(kind: .credential, expected: source, loginID: firstID, intent: intent)
        let second = try await disk.keychain.storeAuthSession(source)
        XCTAssertNotEqual(second.loginID, firstID)
        let replaced = try await disk.keychain.replaceAuthSession(expected: source, expectedLoginID: firstID, with: source)
        XCTAssertFalse(replaced)
        do { _ = try await disk.keychain.finishAccountObservation(ticket, replacement: source); XCTFail("Stale owner accepted") }
        catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        XCTAssertEqual(try disk.root.load(), second)
    }

    func testCopiedOrAbandonedObservationCannotCommit() async throws {
        let disk = AuthenticationTestStorage(), source = session("owner")
        let record = try await disk.keychain.storeAuthSession(source), intent = IOSAuthenticationIntent()
        let loginID = try XCTUnwrap(record.loginID)
        let ticket = try await disk.keychain.beginAccountObservation(kind: .credential, expected: source, loginID: loginID, intent: intent)
        let copy = IOSAuthSessionObservation(observation: ticket.observation, loginID: loginID, source: source,
            intent: intent, requiresCredentialRecovery: ticket.requiresCredentialRecovery)
        do { _ = try await disk.keychain.finishAccountObservation(copy, replacement: source); XCTFail("Copied ticket accepted") }
        catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        await disk.keychain.abandonAccountObservation(ticket)
        do { _ = try await disk.keychain.finishAccountObservation(ticket, replacement: source); XCTFail("Abandoned ticket accepted") }
        catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        XCTAssertEqual(try disk.root.load()?.observations.count, 1)
    }

    func testLegacyMigrationCreatesOneLoginAndRetiresRawCredentials() async throws {
        let disk = AuthenticationTestStorage(), source = session("legacy")
        let bytes = try JSONEncoder().encode(source)
        disk.native.state.withLock { $0.legacy = bytes }
        let first = try await disk.keychain.loadAuthSessionRecordStrict()
        XCTAssertEqual(first?.session, source)
        XCTAssertNotNil(first?.loginID)
        XCTAssertNil(disk.native.state.withLock { $0.legacy })
        let second = try await disk.newKeychainOwner().loadAuthSessionRecordStrict()
        XCTAssertEqual(first, second)
        XCTAssertEqual(disk.native.state.withLock { $0.legacyLoads }, 1)
    }

    func testCorruptCanonicalAndLegacyRecordsFailExplicitly() async throws {
        for canonical in [false, true] {
            let disk = AuthenticationTestStorage()
            let validLegacy = try JSONEncoder().encode(session("legacy"))
            disk.native.state.withLock {
                if canonical {
                    $0.value = ProtectedAccountSessionValue(revision: UUID(), data: Data("not-json".utf8))
                    $0.legacy = validLegacy
                } else { $0.legacy = Data("not-json".utf8) }
            }
            do { _ = try await disk.keychain.loadAuthSessionRecordStrict(); XCTFail("Corruption hidden") }
            catch {
                guard case KeychainError.decodingError = error else { return XCTFail("Storage corruption not reported") }
                XCTAssertEqual(SignalServerClientCompat.presenceFailure(for: error),
                    .localAuthenticationUnavailable(code: "authentication_storage_unavailable"))
            }
            XCTAssertEqual(disk.native.state.withLock { $0.legacyLoads }, canonical ? 0 : 1)
        }
    }

    func testCancellationAfterPreparationBeforeHTTPSettlesOnlyOwnedMarker() async throws {
        let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("cancel-before"), intent: state.beginMutation())
        let expected = try state.witness()
        disk.afterBegin = barrier
        var requests = 0
        let task = Task { try await state.refresh(expected: expected) { _ in requests += 1; return self.session("cancel-before", token: "new") } }
        try await barrier.waitForArrival()
        task.cancel(); barrier.release()
        do { _ = try await task.value; XCTFail("Cancellation hidden") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(try disk.root.load()?.observations, [])
        XCTAssertFalse(state.needsCredentialVerification)
    }

    func testCancellationAfterHTTPLeavesUnknownResultForFreshOwner() async throws {
        let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("cancel-after"), intent: state.beginMutation())
        let expected = try state.witness()
        let task = Task { try await state.refresh(expected: expected) { _ in
            await barrier.wait()
            return self.session("cancel-after", token: "new")
        } }
        try await barrier.waitForArrival()
        task.cancel(); barrier.release()
        do { _ = try await task.value; XCTFail("Cancellation hidden") }
        catch { XCTAssertTrue(error is CancellationError) }
        let restored = IOSAuthenticationSessionState(storage: .live(keychain: disk.newKeychainOwner()))
        _ = try await restored.restore(intent: restored.currentIntent)
        XCTAssertNil(restored.audioAuthorization)
        XCTAssertTrue(restored.needsCredentialVerification)
    }

    func testCancellationAfterDurableCommitStillPublishesCommittedCredentials() async throws {
        let disk = AuthenticationTestStorage(), barrier = AuthenticationTestBarrier()
        let state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("committed"), intent: state.beginMutation())
        let expected = try state.witness(), replacement = session("committed", token: "new")
        disk.afterFinish = barrier
        let task = Task { try await state.refresh(expected: expected) { _ in replacement } }
        try await barrier.waitForArrival()
        XCTAssertEqual(try disk.value, replacement)
        task.cancel(); barrier.release()
        let result = try await task.value
        XCTAssertEqual(result, replacement)
        XCTAssertEqual(state.session, replacement)
        XCTAssertEqual(state.audioAuthorization?.loginID, expected.loginID)
        XCTAssertEqual(try disk.root.load()?.observations, [])
    }

    func testNativeDataProtectionKeychainEnforcesRevisionAndPreservesTombstone() throws {
        let group = try KeychainManager.requiredAccountAccessGroup(
            Bundle.main.object(forInfoDictionaryKey: "SkyBridgeAccountKeychainAccessGroup") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier)
        let service = "com.skybridge.account-tests." + UUID().uuidString
        addTeardownBlock {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: "test",
                kSecAttrAccessGroup as String: group, kSecAttrSynchronizable as String: false]
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw ProtectedAccountSessionError.keychainStatus(status)
            }
        }
        let native = try DataProtectionAccountSessionStorage(service: service, account: "test", accessGroup: group)
        let first = ProtectedAccountSessionStore<AuthSession>(storage: native)
        let installed = try first.install(session("native-keychain"), replacing: nil)
        let observation = ProtectedAccountObservation(kind: .credential)
        let pending = try first.beginObservation(observation, owned: [], replacing: installed)
        let reloaded = ProtectedAccountSessionStore<AuthSession>(storage: native)
        XCTAssertEqual(try reloaded.load(), pending)
        XCTAssertThrowsError(try first.clear(replacing: installed)) {
            XCTAssertEqual($0 as? ProtectedAccountSessionError, .changed)
        }
        let denied = try reloaded.revokeAudio(replacing: pending)
        let settled = try reloaded.finishObservation(observation, replacing: denied)
        XCTAssertTrue(settled.audioRevoked)
        let tombstone = try first.clear(replacing: settled)
        XCTAssertEqual(try reloaded.load(), tombstone)
        XCTAssertNil(tombstone.session)
    }

    func testProtectedAccountFailuresRemainLocalAuthenticationFailures() {
        for error in [ProtectedAccountSessionError.keychainStatus(-25308), .invalidRecord, .verificationRequired] {
            XCTAssertEqual(SignalServerClientCompat.presenceFailure(for: error),
                .localAuthenticationUnavailable(code: "authentication_storage_unavailable"))
        }
        XCTAssertEqual(SignalServerClientCompat.presenceFailure(for:
            IOSAuthenticationPersistenceFailure(original: URLError(.timedOut), persistence: AuthenticationStorageFailure.write)),
            .localAuthenticationUnavailable(code: "authentication_storage_unavailable"))
        XCTAssertEqual(SignalServerClientCompat.presenceFailure(for: IOSAuthenticationSessionError.unownedSessionOperation),
            .localAuthenticationUnavailable(code: "authentication_owner_unavailable"))
    }

    func testApplicationPrivateKeychainGroupRejectsMissingUnexpandedAndSharedGroups() throws {
        let bundle = "com.skybridge.compass.ios"
        XCTAssertEqual(try KeychainManager.requiredAccountAccessGroup("YKUPL7Z869." + bundle, bundleIdentifier: bundle), "YKUPL7Z869." + bundle)
        for group in [nil, "", "$(AppIdentifierPrefix)" + bundle, "YKUPL7Z869.group.com.skybridge.compass", "YKUPL7Z869.other", "bad." + bundle, " YKUPL7Z869." + bundle] {
            XCTAssertThrowsError(try KeychainManager.requiredAccountAccessGroup(group, bundleIdentifier: bundle))
        }
    }

    func testAudioCheckpointPreservesLoginAcrossRefreshAndRejectsStaleRevision() async throws {
        let disk = AuthenticationTestStorage(), state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("audio-owner"), intent: state.beginMutation())
        let authorization = try XCTUnwrap(state.audioAuthorization)
        let initial = try await state.loadAudioMembershipCheckpoint(for: authorization, keychain: disk.keychain)
        let saved = try await state.saveAudioMembershipCheckpoint(Data([1, 2, 3]), replacing: initial.revision,
            for: authorization, keychain: disk.keychain)
        let owner = try state.witness()
        try await state.replace(session("audio-owner", token: "refreshed"), expected: owner)
        let reloaded = try await state.loadAudioMembershipCheckpoint(for: authorization, keychain: disk.keychain)
        XCTAssertEqual(reloaded, saved)
        XCTAssertEqual(try state.witness().loginID, authorization.loginID)
        do {
            _ = try await state.saveAudioMembershipCheckpoint(Data([4]), replacing: initial.revision,
                for: authorization, keychain: disk.keychain)
            XCTFail("Old audio revision overwrote refreshed state")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        XCTAssertEqual(try disk.root.load()?.audioCheckpoint, saved.checkpoint)
    }

    func testInterruptedDeviceRequestKeepsAccountContextButNeverRestoresOldCheckpoint() async throws {
        let disk = AuthenticationTestStorage(), state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("device-recovery"), intent: state.beginMutation())
        let authorization = try XCTUnwrap(state.audioAuthorization)
        let initial = try await state.loadAudioMembershipCheckpoint(for: authorization, keychain: disk.keychain)
        _ = try await state.saveAudioMembershipCheckpoint(Data([1]), replacing: initial.revision,
            for: authorization, keychain: disk.keychain)
        let interrupted = try await state.beginAudioMembershipObservation(for: authorization, keychain: disk.keychain)
        await interrupted.abandon()
        authorization.revoke()
        let keychain = disk.newKeychainOwner()
        let restored = IOSAuthenticationSessionState(storage: .live(keychain: keychain))
        _ = try await restored.restore(intent: restored.currentIntent)
        XCTAssertFalse(restored.needsCredentialVerification)
        let current = try XCTUnwrap(restored.audioAuthorization,
            "A device-list marker must permit fresh account verification without requiring another login")
        XCTAssertEqual(current.loginID, authorization.loginID)
        do {
            _ = try await restored.loadAudioMembershipCheckpoint(for: current, keychain: keychain)
            XCTFail("An interrupted query restored old playback authority")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .verificationRequired) }
        let fresh = try await restored.beginAudioMembershipObservation(for: current, keychain: keychain)
        let empty = try await restored.loadAudioMembershipCheckpoint(for: current, keychain: keychain)
        XCTAssertNil(empty.checkpoint, "The new request must retire uncertain evidence before dispatch")
        _ = try await fresh.finish(empty.revision, .unchanged)
        XCTAssertTrue(try XCTUnwrap(disk.root.load()).observations.isEmpty)
    }

    func testFailedAudioSettlementKeepsItsMarkerAndConsumesTheRequestOwner() async throws {
        let disk = AuthenticationTestStorage(), state = IOSAuthenticationSessionState(storage: disk.dependencies)
        try await state.install(session("failed-audio-write"), intent: state.beginMutation())
        let authorization = try XCTUnwrap(state.audioAuthorization)
        let initial = try await state.loadAudioMembershipCheckpoint(for: authorization, keychain: disk.keychain)
        let saved = try await state.saveAudioMembershipCheckpoint(Data([1]), replacing: initial.revision,
            for: authorization, keychain: disk.keychain)
        let observation = try await state.beginAudioMembershipObservation(for: authorization, keychain: disk.keychain)
        disk.native.state.withLock { $0.failNextWrite = true }
        do { _ = try await observation.finish(saved.revision, .replace(nil)); XCTFail("Write failure hidden") }
        catch { XCTAssertEqual(error as? AuthenticationStorageFailure, .write) }
        do { _ = try await observation.finish(saved.revision, .replace(nil)); XCTFail("Consumed request replayed") }
        catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        do {
            _ = try await state.loadAudioMembershipCheckpoint(for: authorization, keychain: disk.keychain)
            XCTFail("An unsettled negative observation restored a checkpoint")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .verificationRequired) }
        XCTAssertEqual(try disk.root.load()?.observations.count, 1)
    }

    private func session(_ id: String, token: String = "original", name: String = "User") -> AuthSession {
        AuthSession(accessToken: token, refreshToken: "refresh", userIdentifier: id,
                    displayName: name, email: "test@example.invalid", issuedAt: Date(timeIntervalSince1970: 1))
    }
}

private enum AuthenticationStorageFailure: Error { case load, store, delete, write, legacyCleanup }

/// Explicit device qualification uses four independently launched test-host
/// processes. Ordinary suite execution uses an isolated, self-cleaning round trip.
/// Every Keychain item contains synthetic data in a fresh fixture namespace.
@MainActor
final class IOSNativeAccountRecoveryQualificationTests: XCTestCase {
    private static let processToken = UUID().uuidString
    func testNativeAccountRecoveryFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let phase = environment["SKYBRIDGE_NATIVE_RECOVERY_PHASE"] ?? "roundtrip"
        let rawID = environment["SKYBRIDGE_NATIVE_RECOVERY_ID"] ?? UUID().uuidString
        let identifier = try XCTUnwrap(UUID(uuidString: rawID))
        XCTAssertEqual(rawID, identifier.uuidString)
        let fixture = try NativeAccountRecoveryFixture(identifier: identifier)
        if phase == "roundtrip" {
            addTeardownBlock { try fixture.cleanup() }
            for step in ["prepare", "restore", "reject", "cleanup"] {
                try await run(step, fixture: fixture, requiresNewProcess: false)
            }
        } else {
            guard ["prepare", "restore", "reject", "cleanup"].contains(phase),
                  environment["SKYBRIDGE_NATIVE_RECOVERY_ID"] != nil else {
                throw NativeAccountRecoveryFixture.Failure.invalidPhase
            }
            try await run(phase, fixture: fixture, requiresNewProcess: true)
        }
    }

    private func run(_ phase: String, fixture: NativeAccountRecoveryFixture,
                     requiresNewProcess: Bool) async throws {
        let processToken = Self.processToken
        let previous: NativeAccountRecoveryFixture.Checkpoint?
        if phase == "prepare" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.url.path))
            XCTAssertNil(try fixture.root().load())
            XCTAssertNil(try fixture.readLegacy())
            try fixture.seedLegacy()
            previous = nil
        } else {
            previous = try JSONDecoder().decode(NativeAccountRecoveryFixture.Checkpoint.self,
                                               from: Data(contentsOf: fixture.url))
            let checkpoint = try XCTUnwrap(previous)
            let predecessor = ["restore": "prepare", "reject": "restore", "cleanup": "reject"][phase]
            XCTAssertEqual(checkpoint.phase, predecessor)
            XCTAssertEqual(checkpoint.identifier, fixture.identifier)
            if requiresNewProcess {
                XCTAssertNotEqual(checkpoint.pid, getpid(), "Qualification must launch a new test-host process")
                XCTAssertNotEqual(checkpoint.processToken, processToken)
                guard checkpoint.pid != getpid(), checkpoint.processToken != processToken else {
                    throw NativeAccountRecoveryFixture.Failure.sameProcess
                }
            }
            // This is a measured same-boot interval, not a trusted boot identity.
            XCTAssertGreaterThan(mach_continuous_time(), checkpoint.continuousTicks)
        }
        let keychain = try fixture.keychain()
        let state = IOSAuthenticationSessionState(storage: .live(keychain: keychain))
        let restored = try await state.restore(intent: state.currentIntent)
        if phase == "cleanup" {
            XCTAssertNil(restored, "A durable tombstone must not import the synthetic legacy session")
            XCTAssertNil(state.audioAuthorization)
            XCTAssertNil(try fixture.root().load()?.session)
            XCTAssertNil(try fixture.readLegacy())
            try fixture.cleanup()
        } else {
            XCTAssertEqual(restored, fixture.session)
            let record = try XCTUnwrap(fixture.root().load())
            let loginID = try XCTUnwrap(record.loginID)
            if let previous { XCTAssertEqual(loginID, previous.loginID) }
            if phase == "reject" {
                XCTAssertNil(state.audioAuthorization, "An interrupted credential request cannot restore audio authority")
                XCTAssertTrue(state.needsCredentialVerification)
                XCTAssertEqual(record.observations.count, 1)
                try await state.clear(intent: state.beginMutation())
                XCTAssertNil(try fixture.root().load()?.session)
                // A leftover legacy item must not defeat the canonical tombstone.
                try fixture.seedLegacy()
            } else {
                XCTAssertNotNil(state.audioAuthorization)
                XCTAssertFalse(state.needsCredentialVerification)
                XCTAssertNil(try fixture.readLegacy(), "Migration must retire the old synthetic item")
                if phase == "restore" {
                    _ = try await keychain.beginAccountObservation(kind: .credential, expected: fixture.session,
                                                                  loginID: loginID, intent: IOSAuthenticationIntent())
                    XCTAssertEqual(try fixture.root().load()?.observations.count, 1)
                    // Deliberately leave the owned request unresolved, then exit
                    // this test host. No network operation or credential is used.
                }
            }
            let checkpoint = NativeAccountRecoveryFixture.Checkpoint(identifier: fixture.identifier,
                phase: phase, pid: getpid(), processToken: processToken,
                loginID: loginID, continuousTicks: mach_continuous_time())
            try JSONEncoder().encode(checkpoint).write(to: fixture.url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let receipt: [String: String] = [
            "phase": phase, "fixture": fixture.identifier.uuidString, "pid": String(getpid()),
            "separateProcessRequired": String(requiresNewProcess),
            "storage": "native Data Protection Keychain; isolated synthetic account",
            "physicalPlaybackVerified": "false",
        ]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "native-account-recovery-\(phase)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }


}

private struct NativeAccountRecoveryFixture: Sendable {
    enum Failure: Error { case invalidPhase, malformedKeychainValue, sameProcess }
    struct Checkpoint: Codable {
        let identifier: UUID
        let phase: String
        let pid: Int32
        let processToken: String
        let loginID: UUID
        let continuousTicks: UInt64
    }
    let identifier: UUID
    let accessGroup: String
    let service: String
    let url: URL
    var session: AuthSession {
        AuthSession(accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                    userIdentifier: identifier.uuidString, displayName: "Native recovery fixture",
                    email: "fixture@example.invalid", issuedAt: Date(timeIntervalSince1970: 1))
    }
    init(identifier: UUID) throws {
        self.identifier = identifier
        accessGroup = try KeychainManager.requiredAccountAccessGroup(
            Bundle.main.object(forInfoDictionaryKey: "SkyBridgeAccountKeychainAccessGroup") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier)
        service = "com.skybridge.native-account-qualification." + identifier.uuidString
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("NativeAccountQualification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent(identifier.uuidString + ".json")
    }
    func root() throws -> ProtectedAccountSessionStore<AuthSession> {
        ProtectedAccountSessionStore(storage: try storage())
    }
    func storage() throws -> DataProtectionAccountSessionStorage {
        try DataProtectionAccountSessionStorage(service: service, account: "fixture", accessGroup: accessGroup)
    }
    func keychain() throws -> KeychainManager {
        KeychainManager(accountStorage: try storage(), loadLegacy: { try self.readLegacy() },
                        deleteLegacy: { try self.delete(service: self.service + ".legacy") })
    }
    private func query(service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "fixture", kSecAttrAccessGroup as String: accessGroup,
         kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: true]
    }
    func readLegacy() throws -> Data? {
        var attributes = query(service: service + ".legacy")
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ProtectedAccountSessionError.keychainStatus(status) }
        guard let data = result as? Data else { throw Failure.malformedKeychainValue }
        return data
    }
    func seedLegacy() throws {
        var attributes = query(service: service + ".legacy")
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = try JSONEncoder().encode(session)
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw ProtectedAccountSessionError.keychainStatus(status) }
    }
    private func delete(service: String) throws {
        let status = SecItemDelete(query(service: service) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProtectedAccountSessionError.keychainStatus(status)
        }
    }
    func cleanup() throws {
        try delete(service: service)
        try delete(service: service + ".legacy")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

@MainActor
private final class AuthenticationTestBarrier {
    private(set) var arrived = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { arrived = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
    func waitForArrival() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !arrived {
            guard ContinuousClock.now < deadline else { throw XCTFailureGate.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    private enum XCTFailureGate: Error { case timeout }
}

@MainActor
private final class AuthenticationTestStorage {
    let native = AuthenticationProtectedTestStorage()
    var root: ProtectedAccountSessionStore<AuthSession> { ProtectedAccountSessionStore(storage: native) }
    lazy var keychain = newKeychainOwner()
    var value: AuthSession? { get throws { try root.load()?.session } }
    var failure: AuthenticationStorageFailure?
    var beforeStore: AuthenticationTestBarrier?
    var afterStore: AuthenticationTestBarrier?
    var afterReplace: AuthenticationTestBarrier?
    var beforeDelete: AuthenticationTestBarrier?
    var beforeLoadReturn: AuthenticationTestBarrier?
    var afterBegin: AuthenticationTestBarrier?
    var afterFinish: AuthenticationTestBarrier?

    func newKeychainOwner() -> KeychainManager {
        let native = native
        return KeychainManager(accountStorage: native,
            loadLegacy: { try native.loadLegacy() }, deleteLegacy: { try native.deleteLegacy() })
    }
    func seedSession(_ session: AuthSession) throws {
        if let current = try root.load() { _ = try root.refresh(session, replacing: current) }
        else { _ = try root.install(session, replacing: nil) }
    }
    var dependencies: IOSAuthenticationSessionState.Storage {
        let live = IOSAuthenticationSessionState.Storage.live(keychain: keychain)
        return .init(load: { try await self.load(intent: $0) }, store: { try await self.store($0, intent: $1) },
              replace: { try await self.replace($0, with: $1, loginID: $2, intent: $3) },
              delete: { try await self.delete(intent: $0) },
              beginObservation: { try await self.begin($0, loginID: $1, intent: $2) },
              finishObservation: { try await self.finish($0, replacement: $1, temporary: $2) },
              abandonObservation: live.abandonObservation, revokeAudio: live.revokeAudio)
    }
    func begin(_ expected: AuthSession, loginID: UUID, intent: IOSAuthenticationIntent) async throws -> IOSAuthSessionObservation {
        let observation = try await keychain.beginAccountObservation(kind: .credential, expected: expected, loginID: loginID, intent: intent)
        if let afterBegin { await afterBegin.wait() }
        return observation
    }
    func finish(_ observation: IOSAuthSessionObservation, replacement: AuthSession?, temporary: Bool) async throws -> IOSAuthSessionRecord {
        let saved = try await keychain.finishAccountObservation(observation, replacement: replacement, temporaryFailure: temporary)
        if let afterFinish { await afterFinish.wait() }
        return saved
    }
    func load(intent: IOSAuthenticationIntent) async throws -> IOSAuthSessionRecord? {
        let captured = try await keychain.loadAuthSessionRecordStrict(intent: intent), fail = failure == .load
        if let beforeLoadReturn { await beforeLoadReturn.wait() }
        if fail { throw AuthenticationStorageFailure.load }
        return captured
    }
    func store(_ replacement: AuthSession, intent: IOSAuthenticationIntent) async throws -> IOSAuthSessionRecord {
        if let beforeStore { await beforeStore.wait() }
        try intent.requireCurrent()
        if failure == .store { throw AuthenticationStorageFailure.store }
        let saved = try await keychain.storeAuthSession(replacement, intent: intent)
        if let afterStore { await afterStore.wait() }
        return saved
    }
    func replace(_ expected: AuthSession, with replacement: AuthSession, loginID: UUID,
                 intent: IOSAuthenticationIntent) async throws -> Bool {
        let replaced = try await keychain.replaceAuthSession(expected: expected, expectedLoginID: loginID,
                                                            with: replacement, intent: intent)
        if let afterReplace { await afterReplace.wait() }
        return replaced
    }
    func delete(intent: IOSAuthenticationIntent) async throws {
        if let beforeDelete { await beforeDelete.wait() }
        try intent.requireCurrent()
        if failure == .delete { throw AuthenticationStorageFailure.delete }
        try await keychain.deleteAuthSession(intent: intent)
    }
}

/// The production native adapter runs over actual serialized protected records.
/// Failure injection is at the I/O boundary, not a replacement auth implementation.
private final class AuthenticationProtectedTestStorage: ProtectedAccountSessionStorage, Sendable {
    struct State {
        var value: ProtectedAccountSessionValue?
        var failNextWrite = false
        var legacy: Data?
        var legacyLoads = 0
        var failLegacyCleanup = false
    }
    let state = OSAllocatedUnfairLock(initialState: State())
    func load() throws -> ProtectedAccountSessionValue? { state.withLock { $0.value } }
    func insert(_ replacement: ProtectedAccountSessionValue) throws -> Bool {
        try state.withLock { value in
            if value.failNextWrite { value.failNextWrite = false; throw AuthenticationStorageFailure.write }
            guard value.value == nil else { return false }
            value.value = replacement; return true
        }
    }
    func replace(expectedRevision: UUID, with replacement: ProtectedAccountSessionValue) throws -> Bool {
        try state.withLock { value in
            if value.failNextWrite { value.failNextWrite = false; throw AuthenticationStorageFailure.write }
            guard value.value?.revision == expectedRevision else { return false }
            value.value = replacement; return true
        }
    }
    func loadLegacy() throws -> Data? {
        state.withLock { value in
            value.legacyLoads += 1
            guard let bytes = value.legacy else { return nil }
            return bytes
        }
    }
    func deleteLegacy() throws {
        try state.withLock { value in
            if value.failLegacyCleanup { throw AuthenticationStorageFailure.legacyCleanup }
            value.legacy = nil
        }
    }
}

@MainActor
final class IOSKeychainAccessScopeTests: XCTestCase {
    func testOriginalSharedRecordSurvivesScopedReadUpdateAndDelete() throws {
        let fixture = try makeScopedKeychainFixture(self)
        let scope = fixture.scope
        try fixture.insert(Data([1]), group: scope.sharedIdentityGroup)
        var data: CFTypeRef?
        XCTAssertEqual(try scope.copyMatching(fixture.readQuery, &data), errSecSuccess)
        XCTAssertEqual(data as? Data, Data([1]))
        XCTAssertEqual(try scope.update(fixture.query, [kSecValueData as String: Data([2])]), errSecSuccess)
        XCTAssertEqual(try fixture.data(in: scope.sharedIdentityGroup), Data([2]))
        XCTAssertNil(try fixture.data(in: scope.applicationGroup))
        XCTAssertEqual(try scope.delete(fixture.query), errSecSuccess)
        XCTAssertNil(try fixture.data(in: scope.sharedIdentityGroup))
    }

    func testCrossGroupDuplicatesRejectReadUpdateAndDeleteWithoutChangingEitherRecord() throws {
        let fixture = try makeScopedKeychainFixture(self)
        let scope = fixture.scope
        try fixture.insert(Data([1]), group: scope.applicationGroup)
        try fixture.insert(Data([2]), group: scope.sharedIdentityGroup)
        var data: CFTypeRef?
        XCTAssertThrowsError(try scope.copyMatching(fixture.readQuery, &data)) {
            guard case KeychainError.ambiguousAccessGroup = $0 else { return XCTFail("Wrong error: \($0)") }
        }
        XCTAssertThrowsError(try scope.update(fixture.query, [kSecValueData as String: Data([3])])) {
            guard case KeychainError.ambiguousAccessGroup = $0 else { return XCTFail("Wrong error: \($0)") }
        }
        XCTAssertEqual(try fixture.data(in: scope.applicationGroup), Data([1]))
        XCTAssertEqual(try fixture.data(in: scope.sharedIdentityGroup), Data([2]))
        XCTAssertThrowsError(try scope.delete(fixture.query)) {
            guard case KeychainError.ambiguousAccessGroup = $0 else { return XCTFail("Wrong error: \($0)") }
        }
        XCTAssertEqual(try fixture.data(in: scope.applicationGroup), Data([1]))
        XCTAssertEqual(try fixture.data(in: scope.sharedIdentityGroup), Data([2]))
    }

    func testLegacyIdentityEnumerationPreservesBothOriginalLocations() throws {
        let fixture = try makeScopedKeychainFixture(self)
        try fixture.insert(Data([1]), group: fixture.scope.applicationGroup)
        try fixture.insert(Data([2]), group: fixture.scope.sharedIdentityGroup)
        var query = fixture.query
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true
        query[kSecReturnData as String] = true
        query[kSecReturnPersistentRef as String] = true
        var result: CFTypeRef?
        XCTAssertEqual(try fixture.scope.copyMatching(query, &result), errSecSuccess)
        let rows = try XCTUnwrap(result as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.compactMap { $0[kSecAttrAccessGroup as String] as? String }),
                       Set([fixture.scope.applicationGroup, fixture.scope.sharedIdentityGroup]))
        XCTAssertTrue(rows.allSatisfy { ($0[kSecValuePersistentRef as String] as? Data)?.isEmpty == false })
        XCTAssertEqual(Set(rows.compactMap { $0[kSecValueData as String] as? Data }), Set([Data([1]), Data([2])]))
    }

    func testMissingItemsRemainMissingAndNewRecordsUseThePrivateGroup() throws {
        let fixture = try makeScopedKeychainFixture(self)
        var result: CFTypeRef?
        XCTAssertEqual(try fixture.scope.copyMatching(fixture.readQuery, &result), errSecItemNotFound)
        XCTAssertNil(result)
        XCTAssertEqual(try fixture.scope.update(fixture.query, [kSecValueData as String: Data([2])]), errSecItemNotFound)
        XCTAssertEqual(try fixture.scope.delete(fixture.query), errSecItemNotFound)
        var add = fixture.query
        add[kSecValueData as String] = Data([7])
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        XCTAssertEqual(try fixture.scope.add(add), errSecSuccess)
        XCTAssertEqual(try fixture.data(in: fixture.scope.applicationGroup), Data([7]))
        XCTAssertNil(try fixture.data(in: fixture.scope.sharedIdentityGroup))
        XCTAssertEqual(try fixture.scope.add(add), errSecDuplicateItem)
    }

    func testServiceLessLegacyLookupRetainsItsOriginalSharedRecord() throws {
        let fixture = try makeScopedKeychainFixture(self)
        try fixture.insert(Data([5]), group: fixture.scope.sharedIdentityGroup)
        var query = fixture.readQuery
        query.removeValue(forKey: kSecAttrService as String)
        var result: CFTypeRef?
        XCTAssertEqual(try fixture.scope.copyMatching(query, &result), errSecSuccess)
        XCTAssertEqual(result as? Data, Data([5]))
        query.removeValue(forKey: kSecReturnData as String)
        query.removeValue(forKey: kSecMatchLimit as String)
        XCTAssertEqual(try fixture.scope.update(query, [kSecValueData as String: Data([6])]), errSecSuccess)
        XCTAssertEqual(try fixture.data(in: fixture.scope.sharedIdentityGroup), Data([6]))
        XCTAssertNil(try fixture.data(in: fixture.scope.applicationGroup))
        XCTAssertEqual(try fixture.scope.delete(query), errSecSuccess)
        XCTAssertNil(try fixture.data(in: fixture.scope.sharedIdentityGroup))
    }

    func testNativeErrorsAndScopeOverridesAreNotTreatedAsAbsence() throws {
        let fixture = try makeScopedKeychainFixture(self)
        try fixture.insert(Data([4]), group: fixture.scope.applicationGroup)
        var invalid = fixture.readQuery
        invalid[kSecClass as String] = "invalid-keychain-class"
        var result: CFTypeRef?
        let status = try fixture.scope.copyMatching(invalid, &result)
        XCTAssertNotEqual(status, errSecSuccess)
        XCTAssertNotEqual(status, errSecItemNotFound)
        XCTAssertNil(result)
        XCTAssertThrowsError(try fixture.scope.update(invalid, [kSecValueData as String: Data([8])])) {
            guard case KeychainError.unexpectedError(let value) = $0 else { return XCTFail("Wrong error: \($0)") }
            XCTAssertEqual(value, status)
        }
        XCTAssertThrowsError(try fixture.scope.delete(invalid))
        var override = fixture.query
        override[kSecAttrAccessGroup as String] = fixture.scope.sharedIdentityGroup
        XCTAssertThrowsError(try fixture.scope.copyMatching(override, &result))
        XCTAssertThrowsError(try fixture.scope.add(override))
        XCTAssertThrowsError(try fixture.scope.update(fixture.query,
            [kSecAttrAccessGroup as String: fixture.scope.sharedIdentityGroup]))
        XCTAssertThrowsError(try fixture.scope.delete(override))
        XCTAssertEqual(try fixture.data(in: fixture.scope.applicationGroup), Data([4]))
        XCTAssertNil(try fixture.data(in: fixture.scope.sharedIdentityGroup))
    }
}

/// Real Security.framework items in a fresh synthetic namespace. Test-mode
/// in-memory KeychainManager storage is deliberately not involved.
private struct ScopedKeychainFixture: Sendable {
    let scope: IOSLegacyKeychainScope
    let service = "com.skybridge.keychain-scope-tests." + UUID().uuidString
    let account = "scope-fixture." + UUID().uuidString
    let extraGroups: [String]

    var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }

    var readQuery: [String: Any] {
        var result = query
        result[kSecReturnData as String] = true
        result[kSecMatchLimit as String] = kSecMatchLimitOne
        return result
    }

    func insert(_ data: Data, group: String) throws {
        var add = query
        add[kSecAttrAccessGroup as String] = group
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedError(status) }
    }

    func data(in group: String) throws -> Data? {
        var read = readQuery
        read[kSecAttrAccessGroup as String] = group
        var result: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedError(status) }
        guard let data = result as? Data else { throw KeychainError.decodingError }
        return data
    }

    func cleanup() throws {
        for group in [scope.applicationGroup, scope.sharedIdentityGroup] + extraGroups {
            var delete = query
            delete[kSecAttrAccessGroup as String] = group
            let status = SecItemDelete(delete as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainError.unexpectedError(status)
            }
        }
    }
}

@MainActor
private func makeScopedKeychainFixture(_ test: XCTestCase, extraGroups: [String] = []) throws -> ScopedKeychainFixture {
    let fixture = ScopedKeychainFixture(scope: try .current(), extraGroups: extraGroups)
    test.addTeardownBlock { try fixture.cleanup() }
    return fixture
}
