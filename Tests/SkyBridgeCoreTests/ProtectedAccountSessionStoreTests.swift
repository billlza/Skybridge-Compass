import Foundation
import os
import XCTest
@testable import SkyBridgeProtocolCore

final class ProtectedAccountSessionStoreTests: XCTestCase {
    private struct Session: Codable, Equatable, Sendable {
        let subject: String
        let token: String
    }
    private typealias Store = ProtectedAccountSessionStore<Session>
    private let initial = Session(subject: "fixture-user", token: "fixture-token")

    private final class Storage: ProtectedAccountSessionStorage, Sendable {
        struct State {
            var value: ProtectedAccountSessionValue?
            var error: ProtectedAccountSessionError?
            var failAfterCommit = false
            var writes = 0
        }
        let state = OSAllocatedUnfairLock(initialState: State())
        func load() throws -> ProtectedAccountSessionValue? {
            try state.withLock { state in
                if let error = state.error { throw error }
                return state.value
            }
        }
        func insert(_ value: ProtectedAccountSessionValue) throws -> Bool {
            try commit(value, expectedRevision: nil)
        }
        func replace(expectedRevision: UUID, with value: ProtectedAccountSessionValue) throws -> Bool {
            try commit(value, expectedRevision: expectedRevision)
        }
        private func commit(_ value: ProtectedAccountSessionValue, expectedRevision: UUID?) throws -> Bool {
            try state.withLock { state in
                if let error = state.error { throw error }
                guard state.value?.revision == expectedRevision else { return false }
                state.value = value; state.writes += 1
                if state.failAfterCommit { throw ProtectedAccountSessionError.keychainStatus(-36) }
                return true
            }
        }
    }

    func testExplicitLoginRefreshAndReloadPreserveOnlyTheCorrectLifetime() throws {
        let backend = Storage()
        let firstStore = Store(storage: backend)
        XCTAssertNil(try firstStore.load())
        let installed = try firstStore.install(initial, replacing: nil)
        let checkpoint = Data("synthetic-checkpoint-bytes".utf8)
        let saved = try firstStore.saveAudioCheckpoint(checkpoint, replacing: installed)
        let refreshed = try firstStore.refresh(Session(subject: initial.subject, token: "refreshed-fixture"), replacing: saved)
        let reloaded = try XCTUnwrap(Store(storage: backend).load())
        XCTAssertEqual(reloaded, refreshed)
        XCTAssertEqual(reloaded.loginID, installed.loginID)
        XCTAssertEqual(reloaded.audioCheckpoint, checkpoint)
        XCTAssertNotEqual(saved.audioRevision, installed.audioRevision)
        XCTAssertEqual(refreshed.audioRevision, saved.audioRevision)
        XCTAssertFalse(reloaded.audioRevoked)
        XCTAssertNotEqual(reloaded.revision, saved.revision)
        let relogin = try firstStore.install(try XCTUnwrap(reloaded.session), replacing: reloaded)
        XCTAssertNotEqual(relogin.loginID, reloaded.loginID)
        XCTAssertNotEqual(relogin.audioRevision, reloaded.audioRevision)
        XCTAssertNil(relogin.audioCheckpoint)
    }

    func testLogoutTombstoneRejectsStaleRefreshAndAbsentInsert() throws {
        let backend = Storage()
        let activeStore = Store(storage: backend)
        let login = try activeStore.install(initial, replacing: nil)
        let cleared = try activeStore.clear(replacing: login)
        XCTAssertNil(cleared.session); XCTAssertNil(cleared.loginID)
        XCTAssertTrue(cleared.audioRevoked)
        XCTAssertThrowsError(try activeStore.refresh(initial, replacing: login)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .changed) }
        XCTAssertThrowsError(try Store(storage: backend).install(initial, replacing: nil)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .changed) }
        XCTAssertEqual(try activeStore.load(), cleared)
    }

    func testClearOfUninitializedNamespacePreventsLateLegacyPublication() throws {
        let backend = Storage()
        let activeStore = Store(storage: backend)
        let cleared = try activeStore.clear(replacing: nil)
        XCTAssertThrowsError(try activeStore.install(initial, replacing: nil)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .changed) }
        XCTAssertEqual(try activeStore.load(), cleared)
    }

    func testNegativeObservationCannotBeOverwrittenByAnOlderCheckpointOrRefresh() throws {
        let backend = Storage()
        let activeStore = Store(storage: backend)
        let login = try activeStore.install(initial, replacing: nil)
        let saved = try activeStore.saveAudioCheckpoint(Data([1, 2, 3]), replacing: login)
        let revoked = try activeStore.revokeAudio(replacing: saved)
        XCTAssertNotEqual(revoked.audioRevision, saved.audioRevision)
        XCTAssertThrowsError(try activeStore.saveAudioCheckpoint(Data([4]), replacing: saved)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .changed) }
        XCTAssertThrowsError(try activeStore.refresh(initial, replacing: saved)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .changed) }
        XCTAssertThrowsError(try activeStore.saveAudioCheckpoint(Data([4]), replacing: revoked)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .audioRevoked) }
        let refreshed = try activeStore.refresh(initial, replacing: revoked)
        XCTAssertTrue(refreshed.audioRevoked); XCTAssertNil(refreshed.audioCheckpoint)
        XCTAssertEqual(refreshed.loginID, login.loginID)
        XCTAssertEqual(refreshed.audioRevision, revoked.audioRevision)
    }

    func testOldSnapshotCannotClearOrRevokeANewerLogin() throws {
        let backend = Storage()
        let activeStore = Store(storage: backend)
        let first = try activeStore.install(initial, replacing: nil)
        let second = try activeStore.install(initial, replacing: first)
        XCTAssertThrowsError(try activeStore.clear(replacing: first)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .changed) }
        XCTAssertThrowsError(try activeStore.revokeAudio(replacing: first)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .changed) }
        XCTAssertEqual(try activeStore.load(), second)
    }

    func testConcurrentStoreOwnersHaveExactlyOneCommitForOneRevision() throws {
        let backend = Storage(), store = Store(storage: backend)
        let login = try store.install(initial, replacing: nil)
        let results = OSAllocatedUnfairLock(initialState: [Result<Store.Snapshot, Error>]())
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let result = Result { try Store(storage: backend).refresh(Session(subject: "fixture-user", token: "contender-\(index)"), replacing: login) }
            results.withLock { $0.append(result) }
        }
        let replies = results.withLock { $0 }
        XCTAssertEqual(replies.filter { if case .success = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(replies.filter { if case .failure(let error) = $0 { (error as? ProtectedAccountSessionError) == .changed } else { false } }.count, 1)
        XCTAssertEqual(backend.state.withLock { $0.writes }, 2)
    }

    func testStorageFailureIsNotAbsenceOrSuccess() throws {
        let backend = Storage(), store = Store(storage: backend)
        backend.state.withLock { $0.error = .keychainStatus(-25308) }
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .keychainStatus(-25308)) }
        XCTAssertThrowsError(try store.install(initial, replacing: nil)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .keychainStatus(-25308)) }
        XCTAssertEqual(backend.state.withLock { $0.writes }, 0)
    }

    func testUnknownCommitOutcomeCannotReplayOldRevision() throws {
        let backend = Storage(), store = Store(storage: backend)
        let login = try store.install(initial, replacing: nil)
        backend.state.withLock { $0.failAfterCommit = true }
        XCTAssertThrowsError(try store.revokeAudio(replacing: login)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .keychainStatus(-36)) }
        backend.state.withLock { $0.failAfterCommit = false }
        let after = try XCTUnwrap(store.load())
        XCTAssertTrue(after.audioRevoked)
        XCTAssertThrowsError(try store.refresh(initial, replacing: login)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .changed) }
    }

    func testClearedRecordCannotRefreshOrAcceptAudio() throws {
        let backend = Storage(), store = Store(storage: backend)
        let cleared = try store.clear(replacing: nil)
        XCTAssertThrowsError(try store.refresh(initial, replacing: cleared)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .missingSession) }
        XCTAssertThrowsError(try store.revokeAudio(replacing: cleared)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .missingSession) }
        XCTAssertThrowsError(try store.saveAudioCheckpoint(nil, replacing: cleared)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .missingSession) }
    }

    func testCapacityRejectedBeforeAnyMutation() throws {
        let backend = Storage(), store = Store(storage: backend)
        XCTAssertThrowsError(try store.install(Session(subject: "fixture", token: String(repeating: "x", count: Store.maximumSessionBytes)), replacing: nil)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .capacity) }
        XCTAssertEqual(backend.state.withLock { $0.writes }, 0)
        let login = try store.install(initial, replacing: nil)
        XCTAssertThrowsError(try store.saveAudioCheckpoint(Data(count: AudioMembershipCheckpoint.maximumEncodedBytes + 1), replacing: login)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .capacity) }
        XCTAssertEqual(try store.load(), login)
        backend.state.withLock { $0.value = ProtectedAccountSessionValue(revision: UUID(), data: Data(count: Store.maximumEncodedBytes + 1)) }
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .capacity) }
    }

    func testMalformedEnvelopeNeverFallsBackToCredentials() throws {
        let backend = Storage(), store = Store(storage: backend)
        _ = try store.install(initial, replacing: nil)
        let original = try XCTUnwrap(backend.load())
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: original.data) as? [String: Any])
        let zero = "00000000-0000-0000-0000-000000000000"
        let mutations: [(String, Any, ProtectedAccountSessionError)] = [
            ("version", 3, .unsupportedVersion), ("revision", zero, .invalidRecord),
            ("revision", UUID().uuidString, .invalidRecord), ("loginID", zero, .invalidRecord),
            ("audioRevision", zero, .invalidRecord),
            ("loginID", NSNull(), .invalidRecord), ("session", NSNull(), .invalidRecord),
        ]
        for (key, value, error) in mutations {
            var malformed = dictionary; malformed[key] = value
            let data = try JSONSerialization.data(withJSONObject: malformed)
            backend.state.withLock { $0.value = ProtectedAccountSessionValue(revision: original.revision, data: data) }
            XCTAssertThrowsError(try store.load(), key) { XCTAssertEqual($0 as? ProtectedAccountSessionError, error) }
        }
        var revokedWithCheckpoint = dictionary
        revokedWithCheckpoint["audioRevoked"] = true
        revokedWithCheckpoint["audioCheckpoint"] = Data([1]).base64EncodedString()
        let bad = try JSONSerialization.data(withJSONObject: revokedWithCheckpoint)
        backend.state.withLock { $0.value = ProtectedAccountSessionValue(revision: original.revision, data: bad) }
        XCTAssertThrowsError(try store.load()) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .invalidRecord) }
        backend.state.withLock { $0.value = ProtectedAccountSessionValue(revision: original.revision, data: Data("{".utf8)) }
        XCTAssertThrowsError(try store.load()) { XCTAssertTrue($0 is DecodingError) }
    }

    func testNativeLocationValidationDoesNotAccessKeychain() throws {
        for invalid in ["", " trailing ", "embedded\0nul", String(repeating: "x", count: 257)] {
            XCTAssertThrowsError(try DataProtectionAccountSessionStorage(service: invalid, account: "fixture", accessGroup: "fixture-group")) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .invalidRecord) }
            XCTAssertThrowsError(try DataProtectionAccountSessionStorage(service: "fixture", account: "fixture", accessGroup: invalid)) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .invalidRecord) }
        }
    }

    func testCanonicalClearAndActiveStateNeverConsultLegacy() throws {
        let backend = Storage(), store = Store(storage: backend)
        var consulted = false
        let active = try store.install(initial, replacing: nil)
        let loaded = try store.loadMigratingLegacy({ consulted = true; return initial }, requireCurrent: {})
        XCTAssertEqual(loaded, active); XCTAssertFalse(consulted)
        let cleared = try store.clear(replacing: active)
        let after = try store.loadMigratingLegacy({ consulted = true; return initial }, requireCurrent: {})
        XCTAssertEqual(after, cleared); XCTAssertFalse(consulted)
    }

    func testCanonicalReadErrorOrCorruptionCannotFallBackToLegacy() throws {
        let backend = Storage(), store = Store(storage: backend)
        var consulted = false
        backend.state.withLock { $0.error = .keychainStatus(-25308) }
        XCTAssertThrowsError(try store.loadMigratingLegacy({ consulted = true; return initial }, requireCurrent: {})) {
            XCTAssertEqual($0 as? ProtectedAccountSessionError, .keychainStatus(-25308))
        }
        backend.state.withLock {
            $0.error = nil
            $0.value = ProtectedAccountSessionValue(revision: UUID(), data: Data("{".utf8))
        }
        XCTAssertThrowsError(try store.loadMigratingLegacy({ consulted = true; return initial }, requireCurrent: {})) {
            XCTAssertTrue($0 is DecodingError)
        }
        XCTAssertFalse(consulted)
        XCTAssertEqual(backend.state.withLock { $0.writes }, 0)
    }

    func testLegacyImportCreatesOneLoginWithoutInventingMembership() throws {
        let backend = Storage(), store = Store(storage: backend)
        let imported = try XCTUnwrap(store.loadMigratingLegacy({ initial }, requireCurrent: {}))
        XCTAssertEqual(imported.session, initial)
        XCTAssertNotNil(imported.loginID)
        XCTAssertNil(imported.audioCheckpoint)
        XCTAssertFalse(imported.audioRevoked)
        XCTAssertEqual(try store.load(), imported)
        XCTAssertEqual(backend.state.withLock { $0.writes }, 1)
    }

    func testLogoutThatWinsDuringMigrationCannotBeResurrected() throws {
        let backend = Storage(), store = Store(storage: backend)
        let result = try store.loadMigratingLegacy({
            _ = try Store(storage: backend).clear(replacing: nil)
            return initial
        }, requireCurrent: {})
        let record = try XCTUnwrap(result)
        XCTAssertNil(record.session); XCTAssertTrue(record.audioRevoked)
        XCTAssertEqual(try store.load(), record)
        XCTAssertEqual(backend.state.withLock { $0.writes }, 1)
    }

    func testConcurrentNewLoginWinsOverLegacyImport() throws {
        let backend = Storage(), store = Store(storage: backend)
        let newer = Session(subject: "new-fixture", token: "new-fixture-token")
        let result = try store.loadMigratingLegacy({
            _ = try Store(storage: backend).install(newer, replacing: nil)
            return initial
        }, requireCurrent: {})
        XCTAssertEqual(result?.session, newer)
        XCTAssertEqual(backend.state.withLock { $0.writes }, 1)
    }

    func testMigrationCancellationAndLegacyReadFailureDoNotWrite() throws {
        let backend = Storage(), store = Store(storage: backend)
        var checks = 0
        XCTAssertThrowsError(try store.loadMigratingLegacy({ initial }, requireCurrent: {
            checks += 1
            if checks == 2 { throw ProtectedAccountSessionError.changed }
        })) { XCTAssertEqual($0 as? ProtectedAccountSessionError, .changed) }
        XCTAssertThrowsError(try store.loadMigratingLegacy({ throw ProtectedAccountSessionError.keychainStatus(-25308) }, requireCurrent: {})) {
            XCTAssertEqual($0 as? ProtectedAccountSessionError, .keychainStatus(-25308))
        }
        XCTAssertEqual(backend.state.withLock { $0.writes }, 0)
        XCTAssertNil(try store.load())
    }

    func testPreparedRequestsPreserveEachOthersMarkersAndOriginalCheckpoint() throws {
        let backend = Storage(), store = Store(storage: backend)
        let installed = try store.install(initial, replacing: nil)
        let saved = try store.saveAudioCheckpoint(Data([1, 2, 3]), replacing: installed)
        let credential = ProtectedAccountObservation(kind: .credential)
        let device = ProtectedAccountObservation(kind: .devices)
        let first = try store.beginObservation(credential, owned: [], replacing: saved)
        let both = try store.beginObservation(device, owned: [credential.id], replacing: first)
        XCTAssertTrue(both.requiresAudioVerification); XCTAssertTrue(both.requiresCredentialVerification)
        XCTAssertEqual(both.audioCheckpoint, saved.audioCheckpoint)
        XCTAssertThrowsError(try store.refresh(initial, replacing: both)) {
            XCTAssertEqual($0 as? ProtectedAccountSessionError, .verificationRequired)
        }
        let rotated = try store.finishObservation(credential,
            replacementSession: Session(subject: initial.subject, token: "rotated"), replacing: both)
        XCTAssertEqual(rotated.observations, [device])
        XCTAssertEqual(rotated.loginID, installed.loginID)
        XCTAssertEqual(rotated.audioRevision, saved.audioRevision)
        XCTAssertFalse(rotated.requiresCredentialVerification); XCTAssertTrue(rotated.requiresAudioVerification)
        let complete = try store.finishObservation(device, replacing: rotated)
        XCTAssertFalse(complete.requiresAudioVerification)
        XCTAssertEqual(complete.audioCheckpoint, saved.audioCheckpoint)
        XCTAssertThrowsError(try store.finishObservation(credential, replacing: complete))
        XCTAssertEqual(try Store(storage: backend).load(), complete)
    }

    func testFailedSettlementAndNegativeWriteLeaveAnUnresolvedDurableRequest() throws {
        let backend = Storage(), store = Store(storage: backend)
        let active = try store.install(initial, replacing: nil)
        let saved = try store.saveAudioCheckpoint(Data([1]), replacing: active)
        let request = ProtectedAccountObservation(kind: .credential)
        let prepared = try store.beginObservation(request, owned: [], replacing: saved)
        backend.state.withLock { $0.error = .keychainStatus(-36) }
        XCTAssertThrowsError(try store.revokeAudio(replacing: prepared))
        XCTAssertThrowsError(try store.finishObservation(request, replacementSession: initial, replacing: prepared))
        XCTAssertThrowsError(try store.clear(replacing: prepared))
        backend.state.withLock { $0.error = nil }
        let recovered = try XCTUnwrap(Store(storage: backend).load())
        XCTAssertTrue(recovered.requiresAudioVerification); XCTAssertTrue(recovered.requiresCredentialVerification)
        XCTAssertEqual(recovered.observations, [request])
        XCTAssertEqual(recovered.audioCheckpoint, saved.audioCheckpoint)
    }

    func testDeviceQueryCannotRetireAnInterruptedCredentialVerification() throws {
        let backend = Storage(), store = Store(storage: backend)
        let saved = try store.saveAudioCheckpoint(Data([1]), replacing: store.install(initial, replacing: nil))
        let old = ProtectedAccountObservation(kind: .credential)
        let interrupted = try store.beginObservation(old, owned: [], replacing: saved)
        XCTAssertThrowsError(try store.beginObservation(.init(kind: .devices), owned: [], replacing: interrupted)) {
            XCTAssertEqual($0 as? ProtectedAccountSessionError, .verificationRequired)
        }
        let fresh = ProtectedAccountObservation(kind: .credential)
        let prepared = try store.beginObservation(fresh, owned: [], replacing: interrupted)
        XCTAssertEqual(prepared.loginID, saved.loginID); XCTAssertNil(prepared.audioCheckpoint)
        XCTAssertEqual(prepared.observations, [fresh])
        let unavailable = try store.finishObservation(fresh, keepUnverifiedCredential: true, replacing: prepared)
        XCTAssertTrue(unavailable.requiresCredentialVerification)
        let next = ProtectedAccountObservation(kind: .credential)
        let retry = try store.beginObservation(next, owned: [], replacing: unavailable)
        let verified = try store.finishObservation(next, replacementSession: initial, replacing: retry)
        XCTAssertFalse(verified.requiresCredentialVerification); XCTAssertNil(verified.audioCheckpoint)
    }

    func testCheckpointAndRequestSettlementUseOneConditionalWrite() throws {
        let backend = Storage(), store = Store(storage: backend)
        let active = try store.install(initial, replacing: nil)
        let request = ProtectedAccountObservation(kind: .devices)
        let prepared = try store.beginObservation(request, owned: [], replacing: active)
        let before = backend.state.withLock { $0.writes }
        let completed = try store.finishObservation(request, checkpoint: .replace(Data([2, 3])), replacing: prepared)
        XCTAssertEqual(backend.state.withLock { $0.writes }, before + 1)
        XCTAssertNotEqual(completed.audioRevision, prepared.audioRevision)
        XCTAssertEqual(completed.audioCheckpoint, Data([2, 3]))
        XCTAssertTrue(completed.observations.isEmpty)
    }

    func testVersionOneRecordPreservesCredentialsButRequiresFreshVerification() throws {
        let backend = Storage(), store = Store(storage: backend)
        let saved = try store.saveAudioCheckpoint(Data([1]), replacing: store.install(initial, replacing: nil))
        let original = try XCTUnwrap(backend.load())
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: original.data) as? [String: Any])
        fields["version"] = 1; fields.removeValue(forKey: "observations")
        let legacy = try JSONSerialization.data(withJSONObject: fields)
        backend.state.withLock { $0.value = .init(revision: original.revision, data: legacy) }
        let recovered = try XCTUnwrap(store.load())
        XCTAssertEqual(recovered.session, initial); XCTAssertEqual(recovered.loginID, saved.loginID)
        XCTAssertTrue(recovered.requiresCredentialVerification); XCTAssertTrue(recovered.requiresAudioVerification)
        XCTAssertThrowsError(try store.saveAudioCheckpoint(Data([2]), replacing: recovered))
        let request = ProtectedAccountObservation(kind: .credential)
        let prepared = try store.beginObservation(request, owned: [], replacing: recovered)
        XCTAssertNil(prepared.audioCheckpoint)
        XCTAssertEqual(prepared.loginID, recovered.loginID)
        XCTAssertEqual(prepared.version, 2)
    }

    func testObservationCapacityAndDuplicateIdentityRejectBeforeWriting() throws {
        let backend = Storage(), store = Store(storage: backend)
        var current = try store.install(initial, replacing: nil)
        var owned = Set<UUID>()
        for _ in 0..<Store.maximumObservations {
            let request = ProtectedAccountObservation(kind: .devices)
            current = try store.beginObservation(request, owned: owned, replacing: current)
            owned.insert(request.id)
        }
        let before = backend.state.withLock { $0.writes }
        XCTAssertThrowsError(try store.beginObservation(.init(kind: .devices), owned: owned, replacing: current)) {
            XCTAssertEqual($0 as? ProtectedAccountSessionError, .capacity)
        }
        XCTAssertThrowsError(try store.beginObservation(current.observations[0], owned: owned, replacing: current))
        XCTAssertEqual(backend.state.withLock { $0.writes }, before)
    }
}
