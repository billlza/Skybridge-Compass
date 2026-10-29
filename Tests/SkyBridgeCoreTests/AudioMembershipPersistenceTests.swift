import Foundation
import os
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class AudioMembershipPersistenceTests: XCTestCase {
    func testNewStoreRestoresExactGrantWithoutGETOrRenewal() async throws {
        let fixture = try Fixture()
        let first = try await fixture.provider().lease(for: fixture.channel())
        let bytes = try XCTUnwrap(fixture.backend.record().audioCheckpoint)
        fixture.clock.advance(250_000)
        fixture.restartAuthorization()
        let restored = try await fixture.provider(offline: true).lease(for: fixture.channel())
        XCTAssertEqual(restored.evidence, first.evidence)
        XCTAssertNotEqual(restored.ownerID, first.ownerID)
        XCTAssertEqual(try fixture.backend.record().audioCheckpoint, bytes)
        XCTAssertTrue(restored.isCurrent)
    }

    func testExpiredAndDifferentBootCheckpointCannotAuthorizeOffline() async throws {
        for reboot in [false, true] {
            let fixture = try Fixture()
            _ = try await fixture.provider().lease(for: fixture.channel())
            if reboot { fixture.bootID = UUID() } else { fixture.clock.advance(3_600_000) }
            fixture.restartAuthorization()
            await assertOfflineFailure { try await fixture.provider(offline: true).lease(for: fixture.channel()) }
            XCTAssertNil(try fixture.backend.record().audioCheckpoint)
        }
    }

    func testClockRollbackAndMalformedCheckpointAreErrorsWithoutNetworkFallback() async throws {
        for malformed in [false, true] {
            let fixture = try Fixture()
            _ = try await fixture.provider().lease(for: fixture.channel())
            if malformed {
                _ = try fixture.backend.store.saveAudioCheckpoint(Data("invalid".utf8), replacing: fixture.backend.record())
            } else { fixture.clock.advance(-1) }
            fixture.restartAuthorization()
            var gets = 0
            let provider = fixture.provider(fetch: { _, _ in gets += 1; return fixture.response() })
            do { _ = try await provider.lease(for: fixture.channel()); XCTFail("Invalid checkpoint accepted") }
            catch {
                if malformed { XCTAssertTrue(error is DecodingError) }
                else { XCTAssertEqual(error as? AudioMembershipError, .clockMovedBackwards) }
            }
            XCTAssertEqual(gets, 0)
        }
    }

    func testDifferentAuthorityAndIdenticalCredentialReloginRejectOldCheckpoint() async throws {
        for relogin in [false, true] {
            let fixture = try Fixture()
            _ = try await fixture.provider().lease(for: fixture.channel())
            if relogin { _ = try fixture.backend.store.install("fixture", replacing: fixture.backend.record()) }
            else {
                fixture.account = try AudioAccountIdentity(authority: "https://other.example.invalid", tenantID: "tenant", userID: "user")
            }
            var gets = 0
            let provider = fixture.provider(fetch: { _, _ in gets += 1; return fixture.response() })
            do { _ = try await provider.lease(for: fixture.channel()); XCTFail("Old authority accepted") }
            catch {
                if relogin { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
                else { XCTAssertEqual(error as? AudioMembershipCheckpointError, .accountChanged) }
            }
            XCTAssertEqual(gets, 0)
        }
    }

    func testRegistryObservationBeforeFirstLeaseDurablyRemovesRestoredPeer() async throws {
        let fixture = try Fixture()
        _ = try await fixture.provider().lease(for: fixture.channel())
        fixture.restartAuthorization()
        let provider = fixture.provider(offline: true)
        try await fixture.observeRemoval(provider)
        XCTAssertNil(try fixture.backend.record().audioCheckpoint)
        fixture.restartAuthorization()
        await assertOfflineFailure { try await fixture.provider(offline: true).lease(for: fixture.channel()) }
    }

    func testHeartbeatAndExplicitRemovalPersistWithoutRenewingOtherEvidence() async throws {
        for heartbeat in [false, true] {
            let fixture = try Fixture()
            let provider = fixture.provider()
            let lease = try await provider.lease(for: fixture.channel())
            if heartbeat {
                let response = try JSONDecoder().decode(SignalServerClient.PresenceRegisterResponseBody.self,
                    from: Data(#"{"online":true,"persisted":false,"persistReason":"device_not_active"}"#.utf8))
                try await fixture.heartbeat(provider, response: response)
            } else { try await fixture.remove(provider) }
            XCTAssertFalse(lease.isCurrent)
            XCTAssertNil(try fixture.backend.record().audioCheckpoint)
            fixture.restartAuthorization()
            await assertOfflineFailure { try await fixture.provider(offline: true).lease(for: fixture.channel()) }
        }
    }

    func testWriteFailureIsVisibleAndCannotLeaveAnyLeaseUsable() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let existing = try await provider.lease(for: fixture.channel())
        do {
            try await fixture.observeRemoval(provider) {
                XCTAssertEqual(try fixture.backend.record().observations.count, 1)
                fixture.backend.saveError = .keychainStatus(-36)
            }
            XCTFail("Write failure hidden")
        }
        catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .keychainStatus(-36)) }
        XCTAssertFalse(existing.isCurrent)
        fixture.backend.saveError = nil
        do { _ = try await provider.lease(for: fixture.channel()); XCTFail("Uncommitted revocation restored") }
        catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .keychainStatus(-36)) }
    }

    func testFailedNegativeWriteCannotRestoreTheDeniedGrantInANewProvider() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let existing = try await provider.lease(for: fixture.channel())
        do {
            try await fixture.observeRemoval(provider) {
                XCTAssertEqual(try fixture.backend.record().observations.count, 1)
                fixture.backend.saveError = .keychainStatus(-36)
            }
            XCTFail("Write failure hidden")
        }
        catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .keychainStatus(-36)) }
        XCTAssertFalse(existing.isCurrent)

        // A fresh coordinator has no process-local failure latch. It reads the actual
        // protected record bytes that survived the failed negative observation.
        fixture.backend.saveError = nil
        fixture.restartAuthorization()
        do {
            let restored = try await fixture.provider(offline: true).lease(for: fixture.channel())
            XCTAssertFalse(restored.isCurrent,
                "A new provider restored audio authority after its negative write failed")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet,
                "Recovery must require a new GET, not fail for an unrelated fixture reason")
        }
        XCTAssertNil(try fixture.backend.record().audioCheckpoint)
        XCTAssertTrue(try fixture.backend.record().observations.isEmpty)
    }

    func testPreparationFailurePreventsDispatchWithoutChangingThePriorGrant() async throws {
        let fixture = try Fixture(), provider = fixture.provider()
        let prior = try await provider.lease(for: fixture.channel())
        let record = try fixture.backend.record()
        fixture.backend.prepareError = .keychainStatus(-36)
        var dispatched = false
        do {
            try await provider.observeRequest(context: fixture.context) { _ in dispatched = true }
            XCTFail("Failed preparation dispatched a request")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .keychainStatus(-36)) }
        XCTAssertFalse(dispatched)
        XCTAssertEqual(try fixture.backend.record(), record)
        XCTAssertTrue(prior.isCurrent)
    }

    func testTemporaryRenewalFailureSettlesMarkerAndRestoresTheOriginalExpiry() async throws {
        let fixture = try Fixture()
        var gets = 0
        let provider = fixture.provider(fetch: { _, _ in
            gets += 1
            if gets > 1 { throw URLError(.notConnectedToInternet) }
            return fixture.response()
        })
        let channel = fixture.channel(), lease = try await provider.lease(for: channel)
        let prior = lease.evidence, record = try fixture.backend.record()
        fixture.clock.advance(1_000)
        do { _ = try await provider.renew(for: channel, continuing: lease); XCTFail("Offline request renewed") }
        catch let error as AudioMembershipRequestUnavailable {
            XCTAssertEqual((error.underlying as? URLError)?.code, .notConnectedToInternet)
        }
        let settled = try fixture.backend.record()
        XCTAssertTrue(settled.observations.isEmpty)
        XCTAssertEqual(settled.audioRevision, record.audioRevision)
        XCTAssertEqual(settled.audioCheckpoint, record.audioCheckpoint)
        XCTAssertEqual(lease.evidence, prior)
        XCTAssertTrue(lease.isCurrent)
        fixture.restartAuthorization()
        let restored = try await fixture.provider(offline: true).lease(for: fixture.channel())
        XCTAssertEqual(restored.evidence, prior)
        XCTAssertEqual(gets, 2)
    }

    func testTemporaryFailureWithFailedSettlementLeavesAnUnresolvedDurableRequest() async throws {
        let fixture = try Fixture(), provider = fixture.provider()
        let prior = try await provider.lease(for: fixture.channel())
        do {
            try await provider.observeRequest(context: fixture.context) { _ -> Void in
                fixture.backend.saveError = .keychainStatus(-36)
                throw URLError(.notConnectedToInternet)
            }
            XCTFail("Both failures were hidden")
        } catch let failure as AudioObservationSettlementFailure {
            XCTAssertEqual((failure.original as? URLError)?.code, .notConnectedToInternet)
            XCTAssertEqual(failure.settlement as? ProtectedAccountSessionError, .keychainStatus(-36))
        }
        XCTAssertFalse(prior.isCurrent)
        XCTAssertEqual(try fixture.backend.record().observations.count, 1)
        XCTAssertTrue(fixture.backend.ownedObservations.isEmpty)
        fixture.backend.saveError = nil
        fixture.restartAuthorization()
        await assertOfflineFailure { try await fixture.provider(offline: true).lease(for: fixture.channel()) }
        XCTAssertNil(try fixture.backend.record().audioCheckpoint)
    }

    func testLostRemovalResponseCannotSettleAsAnOfflineRead() async throws {
        let fixture = try Fixture(), provider = fixture.provider()
        _ = try await provider.lease(for: fixture.channel())
        do {
            try await provider.observeRequest(context: fixture.context, allowTemporaryFailure: false) { _ -> Void in
                throw URLError(.networkConnectionLost)
            }
            XCTFail("Lost removal response hidden")
        } catch { XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost) }
        XCTAssertEqual(try fixture.backend.record().observations.count, 1)
        XCTAssertTrue(fixture.backend.ownedObservations.isEmpty)
        fixture.restartAuthorization()
        await assertOfflineFailure { try await fixture.provider(offline: true).lease(for: fixture.channel()) }
        XCTAssertNil(try fixture.backend.record().audioCheckpoint)
    }

    func testExternalAudioMutationRejectsOldSaveWithoutOverwritingWinner() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let existing = try await provider.lease(for: fixture.channel())
        let gate = Gate(); fixture.backend.saveGate = gate
        let refresh = Task { try await provider.lease(for: fixture.channel(), refresh: true) }
        await gate.waitUntilStarted()
        let winner = try fixture.backend.store.revokeAudio(replacing: fixture.backend.record())
        gate.release()
        do { _ = try await refresh.value; XCTFail("CAS conflict hidden") }
        catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        XCTAssertFalse(existing.isCurrent)
        XCTAssertEqual(try fixture.backend.record(), winner)
    }

    func testContinuationDoesNotPublishUntilProtectedSaveReturns() async throws {
        for failWrite in [false, true] {
            let fixture = try Fixture()
            let provider = fixture.provider()
            let channel = fixture.channel()
            let lease = try await provider.lease(for: channel)
            let original = lease.evidence, record = try fixture.backend.record()
            fixture.clock.advance(1_000)
            let gate = Gate(); fixture.backend.saveGate = gate
            let renewal = Task { try await provider.renew(for: channel, continuing: lease) }
            await gate.waitUntilStarted()
            let prepared = try fixture.backend.record()
            do {
                defer { gate.release() }
                XCTAssertTrue(lease.isCurrent)
                XCTAssertEqual(lease.evidence, original)
                XCTAssertNotEqual(prepared.revision, record.revision)
                XCTAssertEqual(prepared.observations.count, 1)
                XCTAssertEqual(prepared.session, record.session)
                XCTAssertEqual(prepared.loginID, record.loginID)
                XCTAssertEqual(prepared.audioRevision, record.audioRevision)
                XCTAssertEqual(prepared.audioCheckpoint, record.audioCheckpoint)
                if failWrite { fixture.backend.saveError = .keychainStatus(-36) }
            }
            if failWrite {
                do { _ = try await renewal.value; XCTFail("Failed write published a continuation") }
                catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .keychainStatus(-36)) }
                XCTAssertFalse(lease.isCurrent)
                XCTAssertEqual(lease.evidence, original)
                XCTAssertEqual(try fixture.backend.record(), prepared)
            } else {
                let renewed = try await renewal.value
                XCTAssertTrue(renewed === lease)
                XCTAssertTrue(lease.isCurrent)
                XCTAssertNotEqual(lease.evidence.id, original.id)
                let committed = lease.evidence
                fixture.restartAuthorization()
                let restored = try await fixture.provider(offline: true).lease(for: fixture.channel())
                XCTAssertEqual(restored.evidence, committed)
            }
        }
    }

    func testRemovalDuringContinuationSaveRevokesThePredecessorBeforeDiskCompletes() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let channel = fixture.channel()
        let lease = try await provider.lease(for: channel)
        let original = lease.evidence
        let receipt = Gate()
        let removal = Task { try await fixture.remove(provider) { await receipt.wait() } }
        await receipt.waitUntilStarted()
        fixture.clock.advance(1_000)
        let gate = Gate(); fixture.backend.saveGate = gate
        let renewal = Task { try await provider.renew(for: channel, continuing: lease) }
        await gate.waitUntilStarted()
        XCTAssertTrue(lease.isCurrent)
        receipt.release()
        for _ in 0..<100 where lease.isCurrent { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(lease.isCurrent, "Old output authorization survived a known removal during the new write")
        XCTAssertEqual(lease.evidence, original)
        gate.release()
        do { _ = try await renewal.value; XCTFail("Late positive write revived the stream") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
        try await removal.value
        XCTAssertFalse(lease.isCurrent)
        XCTAssertNil(try fixture.backend.record().audioCheckpoint)
        fixture.restartAuthorization()
        await assertOfflineFailure { try await fixture.provider(offline: true).lease(for: fixture.channel()) }
    }

    func testExpiryWhileContinuationSaveIsBlockedCannotReviveTheStream() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let channel = fixture.channel()
        let lease = try await provider.lease(for: channel)
        let original = lease.evidence
        fixture.clock.advance(1_000)
        let gate = Gate(); fixture.backend.saveGate = gate
        let renewal = Task { try await provider.renew(for: channel, continuing: lease) }
        await gate.waitUntilStarted()
        fixture.clock.advance(3_599_000)
        XCTAssertEqual(lease.failure, .expired)
        gate.release()
        do { _ = try await renewal.value; XCTFail("Expired owner resumed after a delayed write") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .expired) }
        XCTAssertEqual(lease.evidence, original)
        XCTAssertEqual(lease.failure, .expired)
    }

    func testCachedGrantChecksDurableRevocationAndReplacement() async throws {
        for mutation in 0..<4 {
            let fixture = try Fixture()
            let provider = fixture.provider()
            let lease = try await provider.lease(for: fixture.channel())
            let record = try fixture.backend.record()
            switch mutation {
            case 0: _ = try fixture.backend.store.clear(replacing: record)
            case 1: _ = try fixture.backend.store.revokeAudio(replacing: record)
            case 2: _ = try fixture.backend.store.install("fixture", replacing: record)
            default: _ = try fixture.backend.store.saveAudioCheckpoint(nil, replacing: record)
            }
            let winner = try fixture.backend.record()
            do { _ = try await provider.lease(for: fixture.channel()); XCTFail("Cached grant ignored durable mutation \(mutation)") }
            catch {
                XCTAssertEqual(error as? ProtectedAccountSessionError, mutation == 1 ? .audioRevoked : .changed)
            }
            XCTAssertFalse(lease.isCurrent, "Old consumer survived durable mutation \(mutation)")
            XCTAssertEqual(try fixture.backend.record(), winner)
        }
    }

    func testCachedGrantSurvivesCredentialOnlyRefreshWithoutRenewal() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let first = try await provider.lease(for: fixture.channel())
        _ = try fixture.backend.store.refresh("new-fixture-token", replacing: fixture.backend.record())
        let second = try await provider.lease(for: fixture.channel())
        XCTAssertEqual(second.evidence, first.evidence)
        XCTAssertTrue(first.isCurrent)
    }

    func testRemovalDuringProtectedSaveRevokesImmediatelyAndWinsDurably() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let existing = try await provider.lease(for: fixture.channel())
        let receipt = Gate()
        let removal = Task { try await fixture.remove(provider) { await receipt.wait() } }
        await receipt.waitUntilStarted()
        let gate = Gate()
        fixture.backend.saveGate = gate
        let refresh = Task { try await provider.lease(for: fixture.channel(), refresh: true) }
        await gate.waitUntilStarted()
        // The old lease is already revoked by replacement. Use a cancelled
        // presentation as well: a completed negative fact still must persist.
        removal.cancel()
        receipt.release()
        await Task.yield()
        gate.release()
        do { _ = try await refresh.value; XCTFail("Pending grant survived removal") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
        try await removal.value
        XCTAssertFalse(existing.isCurrent)
        XCTAssertNil(try fixture.backend.record().audioCheckpoint)
        fixture.restartAuthorization()
        await assertOfflineFailure { try await fixture.provider(offline: true).lease(for: fixture.channel()) }
    }

    func testLiveLeaseStopsBeforeBlockedRevocationWriteCompletes() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider()
        let lease = try await provider.lease(for: fixture.channel())
        let original = try fixture.backend.record()
        let gate = Gate(); fixture.backend.saveGate = gate
        let removal = Task { try await fixture.remove(provider) }
        await gate.waitUntilStarted()
        XCTAssertFalse(lease.isCurrent, "Live output remained admitted while revocation waited for storage")
        let prepared = try fixture.backend.record()
        XCTAssertEqual(prepared.audioCheckpoint, original.audioCheckpoint, "Negative write must still be held")
        XCTAssertEqual(prepared.audioRevision, original.audioRevision)
        XCTAssertEqual(prepared.observations.count, 1, "Preparation must precede the response")
        removal.cancel()
        gate.release()
        try await removal.value
        XCTAssertNil(try fixture.backend.record().audioCheckpoint)
    }

    func testPreparedRemovalWhileCheckpointValidationIsSuspendedCannotReturnRestoredLease() async throws {
        let fixture = try Fixture()
        _ = try await fixture.provider().lease(for: fixture.channel())
        fixture.restartAuthorization()
        let provider = fixture.provider(offline: true)
        let receipt = Gate()
        let removal = Task { try await fixture.remove(provider) { await receipt.wait() } }
        await receipt.waitUntilStarted()
        let gate = Gate(); fixture.backend.loadGate = gate
        let restore = Task { try await provider.lease(for: fixture.channel()) }
        await gate.waitUntilStarted()
        receipt.release()
        await Task.yield()
        gate.release()
        await assertOfflineFailure { try await restore.value }
        try await removal.value
        XCTAssertNil(try fixture.backend.record().audioCheckpoint)
    }

    func testCredentialRefreshPreservesCheckpointAndItsAudioRevision() async throws {
        let fixture = try Fixture()
        let original = try await fixture.provider().lease(for: fixture.channel())
        let saved = try fixture.backend.record()
        let refreshed = try fixture.backend.store.refresh("refreshed-fixture", replacing: saved)
        XCTAssertEqual(refreshed.audioRevision, saved.audioRevision)
        fixture.restartAuthorization()
        let restored = try await fixture.provider(offline: true).lease(for: fixture.channel())
        XCTAssertEqual(restored.evidence, original.evidence)
    }

    func testMacKernelBootIdentityIsStableAcrossIndependentReads() throws {
        XCTAssertEqual(try MacAudioBootSessionID.read(), try MacAudioBootSessionID.read())
    }

    func testSuspendedClockReadCannotPersistARevokedPeerDuringRenewal() async throws {
        let fixture = try Fixture(), reader = BootReader()
        reader.identifier = fixture.bootID
        let provider = fixture.provider(bootRead: { try await reader.read() })
        let channel = fixture.channel()
        let prior = try await provider.lease(for: channel)
        fixture.clock.advance(1_000)
        let receipt = Gate()
        let removal = Task { try await fixture.remove(provider) { await receipt.wait() } }
        await receipt.waitUntilStarted()
        let clockGate = Gate(); reader.gate = clockGate
        let renewal = Task { try await provider.renew(for: channel, continuing: prior) }
        await clockGate.waitUntilStarted()
        receipt.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while prior.isCurrent && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertFalse(prior.isCurrent, "Removal must revoke the predecessor before clock I/O finishes")
        let writes = fixture.backend.checkpointCommits.count
        clockGate.release()
        do { _ = try await renewal.value; XCTFail("A revoked renewal was published") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
        try await removal.value
        XCTAssertTrue(fixture.backend.checkpointCommits.dropFirst(writes).allSatisfy { $0 == nil },
                      "No intermediate protected write may reintroduce the revoked peer")
        XCTAssertNil(try fixture.backend.record().audioCheckpoint)
        XCTAssertTrue(try fixture.backend.record().observations.isEmpty)
    }

    func testGrantExpiringDuringClockReadSettlesWithoutPersistingExpiredEvidence() async throws {
        let fixture = try Fixture(), reader = BootReader()
        reader.identifier = fixture.bootID
        let gate = Gate(); reader.gate = gate
        let provider = fixture.provider(bootRead: { try await reader.read() })
        let request = Task { try await provider.lease(for: fixture.channel()) }
        await gate.waitUntilStarted()
        fixture.clock.advance(3_600_000)
        gate.release()
        do { _ = try await request.value; XCTFail("Expired grant published") }
        catch { XCTAssertEqual(error as? AudioMembershipError, .expired) }
        XCTAssertNil(try fixture.backend.record().audioCheckpoint)
        XCTAssertTrue(try fixture.backend.record().observations.isEmpty)
    }

    func testUnavailableClockRejectsRestorationWithoutIssuingAnotherGET() async throws {
        let fixture = try Fixture()
        _ = try await fixture.provider().lease(for: fixture.channel())
        fixture.restartAuthorization()
        var gets = 0
        let provider = fixture.provider(fetch: { _, _ in gets += 1; return fixture.response() },
            bootRead: { throw BootReader.Failure.unavailable })
        do { _ = try await provider.lease(for: fixture.channel()); XCTFail("Clock failure became authority") }
        catch { XCTAssertEqual(error as? BootReader.Failure, .unavailable) }
        XCTAssertEqual(gets, 0)
    }

    private func assertOfflineFailure(_ operation: () async throws -> AudioMembershipLease,
                                      file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Offline request obtained a new grant", file: file, line: line) }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet, file: file, line: line) }
    }
}

@MainActor
private final class Fixture {
    let backend: Backend
    let binding: ProtocolIdentityBinding
    let local: AudioProtocolIdentity
    let peer: AudioProtocolIdentity
    let clock = TestClock()
    var bootID = UUID()
    var account: AudioAccountIdentity
    var authorization: AccountAudioAuthorization
    var context: AudioAccountContext { .init(authorization: authorization, account: account) }

    init() throws {
        backend = try Backend()
        authorization = AccountAudioAuthorization(loginID: try XCTUnwrap(backend.record().loginID))
        account = try .init(authority: "https://signal.example.invalid", tenantID: "tenant", userID: "user")
        binding = try .init(deviceId: "persist-local-device-0001", protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x47, count: 32))
        local = try .init(binding)
        peer = try .init(deviceID: "persist-peer-device-0002", algorithm: .ed25519, fingerprint: String(repeating: "b", count: 64))
    }
    func restartAuthorization() {
        let id = authorization.loginID
        backend.ownedObservations.removeAll()
        authorization.revoke(); authorization = AccountAudioAuthorization(loginID: id)
    }
    func channel() -> P2PAudioChannel {
        let mailbox = P2PAudioMailbox()
        return P2PAudioChannel(mailbox: mailbox, remoteIdentity: peer, localIdentityBinding: binding, controlTransport: .network,
            validateOwner: {}, send: { _, effect in try effect?() }, close: { mailbox.finish(.closed) })
    }
    func provider(offline: Bool = false,
                  fetch: (@MainActor (AudioAccountContext, ProtocolIdentityBinding) async throws -> AccountDeviceListSnapshot)? = nil,
                  bootRead: (@Sendable () async throws -> UUID)? = nil)
        -> AudioAccountMembershipProvider {
        let captured = context, boot = bootID
        return AudioAccountMembershipProvider(currentContext: { captured }, fetch: fetch ?? { _, _ in
            if offline { throw URLError(.notConnectedToInternet) }
            return self.response()
        }, wall: { [clock] in clock.wall }, monotonic: { [clock] in clock.monotonic },
        persistence: AudioMembershipPersistence(bootSessionID: bootRead ?? { boot },
            load: { [backend] in try await backend.load($0) },
            save: { [backend] in try await backend.save($0, revision: $1, bytes: $2) },
            beginObservation: { [backend] in try backend.begin($0) }))
    }
    func response(includePeer: Bool = true) -> AccountDeviceListSnapshot {
        let identities = includePeer ? [local, peer] : [local]
        let rows = identities.map { identity in
            AccountDeviceRecord(deviceId: identity.deviceID, deviceName: nil, status: "active",
                protocolSigningAlgorithm: identity.algorithm.rawValue, protocolPublicKeyFingerprint: identity.fingerprint,
                platformRawValue: nil, deviceModel: nil, osVersion: nil, appVersion: nil, lanAddresses: [], publicAddress: nil,
                capabilities: [], registeredAtEpochMilliseconds: nil, lastSeenAtEpochMilliseconds: nil,
                presenceUpdatedAtEpochMilliseconds: nil, online: false, isCaller: identity == local)
        }
        return .init(generatedAtEpochMilliseconds: clock.wall, callerDeviceId: local.deviceID,
            truncated: false, devices: rows, accountScope: account.serverScope)
    }
    func observeRemoval(_ provider: AudioAccountMembershipProvider,
                        afterPreparation: @MainActor () async throws -> Void = {}) async throws {
        try await provider.observeRequest(context: context) { observation in
            try await afterPreparation()
            try await provider.observeFreshRegistry(response(includePeer: false), context: context, caller: local,
                startedWall: clock.wall, receivedWall: clock.wall,
                startedMonotonic: clock.monotonic, receivedMonotonic: clock.monotonic, observation: observation)
        }
    }
    func remove(_ provider: AudioAccountMembershipProvider,
                afterPreparation: @MainActor () async throws -> Void = {}) async throws {
        try await provider.observeRequest(context: context, allowTemporaryFailure: false) { observation in
            try await afterPreparation()
            try await provider.revoke(identity: peer, context: context, observation: observation)
        }
    }
    func heartbeat(_ provider: AudioAccountMembershipProvider,
                   response: SignalServerClient.PresenceRegisterResponseBody) async throws {
        try await provider.observeRequest(context: context) { observation in
            try await provider.observeHeartbeat(response, context: context, caller: local, observation: observation)
        }
    }
}

@MainActor
private final class Backend {
    let store = ProtectedAccountSessionStore<String>(storage: InMemoryProtectedAccountSessionStorage())
    var loadGate: Gate?
    var saveGate: Gate?
    var saveError: ProtectedAccountSessionError?
    var prepareError: ProtectedAccountSessionError?
    var ownedObservations = Set<UUID>()
    var checkpointCommits: [Data?] = []
    init() throws { _ = try store.install("fixture", replacing: nil) }
    func record() throws -> ProtectedAccountSessionStore<String>.Snapshot { try XCTUnwrap(store.load()) }
    func load(_ context: AudioAccountContext) async throws -> AudioMembershipPersistenceSnapshot {
        let snapshot = try record()
        if let gate = loadGate { loadGate = nil; await gate.wait() }
        guard snapshot.loginID == context.authorization.loginID else { throw ProtectedAccountSessionError.changed }
        guard !snapshot.audioRevoked else { throw ProtectedAccountSessionError.audioRevoked }
        guard snapshot.version == 2, snapshot.observations.allSatisfy({ ownedObservations.contains($0.id) }) else {
            throw ProtectedAccountSessionError.verificationRequired
        }
        return .init(revision: snapshot.audioRevision, checkpoint: snapshot.audioCheckpoint)
    }
    func save(_ context: AudioAccountContext, revision: UUID, bytes: Data?) async throws -> AudioMembershipPersistenceSnapshot {
        if let gate = saveGate { saveGate = nil; await gate.wait() }
        if let saveError { throw saveError }
        let current = try record()
        guard current.loginID == context.authorization.loginID, current.audioRevision == revision else {
            throw ProtectedAccountSessionError.changed
        }
        let saved = try store.saveAudioCheckpoint(bytes, replacing: current)
        checkpointCommits.append(saved.audioCheckpoint)
        return .init(revision: saved.audioRevision, checkpoint: saved.audioCheckpoint)
    }
    func begin(_ context: AudioAccountContext) throws -> AudioMembershipPersistenceObservation {
        if let prepareError { throw prepareError }
        let current = try record()
        guard current.loginID == context.authorization.loginID else { throw ProtectedAccountSessionError.changed }
        let observation = ProtectedAccountObservation(kind: .devices)
        _ = try store.beginObservation(observation, owned: ownedObservations, replacing: current)
        ownedObservations.insert(observation.id)
        return AudioMembershipPersistenceObservation(finish: { revision, update in
            // The gate models a write waiting for its native executor. Consume
            // ownership immediately before the synchronous protected transaction.
            if let gate = self.saveGate { self.saveGate = nil; await gate.wait() }
            guard self.ownedObservations.remove(observation.id) != nil else {
                throw ProtectedAccountSessionError.changed
            }
            if let error = self.saveError { throw error }
            let current = try self.record()
            guard current.loginID == context.authorization.loginID,
                  revision == nil || revision == current.audioRevision else {
                throw ProtectedAccountSessionError.changed
            }
            let saved = try self.store.finishObservation(observation, checkpoint: update, replacing: current)
            self.checkpointCommits.append(saved.audioCheckpoint)
            return .init(revision: saved.audioRevision, checkpoint: saved.audioCheckpoint)
        }, abandon: { self.ownedObservations.remove(observation.id) })
    }
}

@MainActor
private final class BootReader {
    enum Failure: Error, Equatable { case unavailable }
    var identifier = UUID()
    var gate: Gate?
    func read() async throws -> UUID {
        if let gate { self.gate = nil; await gate.wait() }
        return identifier
    }
}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; started?.resume(); started = nil }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { precondition(continuation != nil); continuation?.resume(); continuation = nil }
}

private final class TestClock: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: (Int64(1_000_000), ContinuousClock.now))
    var wall: Int64 { value.withLock { $0.0 } }
    var monotonic: ContinuousClock.Instant { value.withLock { $0.1 } }
    func advance(_ milliseconds: Int64) {
        value.withLock { $0.0 += milliseconds; $0.1 = $0.1.advanced(by: .milliseconds(milliseconds)) }
    }
}
