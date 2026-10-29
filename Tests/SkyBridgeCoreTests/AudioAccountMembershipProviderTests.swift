import Foundation
import XCTest
import os
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class AudioAccountMembershipProviderTests: XCTestCase {
    func testAccountMutationRevokesBeforeReplacementAndCannotReviveOldEpoch() throws {
        let state = AccountAudioAuthorizationState()
        XCTAssertNil(state.current)
        state.publishAuthenticatedSession()
        let first = try XCTUnwrap(state.current)
        try state.requireCurrent(first) // A validated refresh does not publish a new login epoch.
        state.beginMutation()
        XCTAssertFalse(first.isCurrent)
        XCTAssertNil(state.current) // Failed persistence must leave this unavailable.
        XCTAssertThrowsError(try state.requireCurrent(first))
        state.publishAuthenticatedSession()
        XCTAssertFalse(first.isCurrent)
        XCTAssertFalse(state.current === first)
        try state.requireCurrent(XCTUnwrap(state.current))
    }

    func testAbandonedRequestObservationCannotBeReusedAfterItsBoundaryReturns() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider { _, _ in fixture.response() }
        let lease = try await provider.lease(for: fixture.channel())
        var escaped: AudioAccountMembershipStore.RequestObservation?
        do {
            try await provider.observeRequest(context: fixture.context) { observation -> Void in
                escaped = observation
                throw CancellationError()
            }
            XCTFail("Cancellation hidden")
        } catch { XCTAssertTrue(error is CancellationError) }
        do {
            try await provider.revoke(identity: fixture.peer, context: fixture.context,
                                      observation: XCTUnwrap(escaped))
            XCTFail("An abandoned request revoked a later consumer")
        } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
        XCTAssertTrue(lease.isCurrent)
    }

    func testRequestObservationCannotCrossMembershipStoreOwners() async throws {
        let fixture = try Fixture()
        let first = fixture.provider { _, _ in fixture.response() }
        let second = fixture.provider { _, _ in fixture.response() }
        let lease = try await second.lease(for: fixture.channel())
        try await first.observeRequest(context: fixture.context) { observation in
            do {
                try await second.revoke(identity: fixture.peer, context: fixture.context, observation: observation)
                XCTFail("A different store accepted this request's observation")
            } catch { XCTAssertEqual(error as? ProtectedAccountSessionError, .changed) }
            XCTAssertTrue(lease.isCurrent)
        }
    }

    func testRefreshErrorsRequireKnownSessionRejectionCode() {
        for code in ["session_not_found", "session_expired", "refresh_token_not_found", "refresh_token_already_used", "user_banned", "user_not_found"] {
            XCTAssertTrue(AudioAccountRefreshFailurePolicy.invalidatesAuthorization(status: 400, body: "{\"error_code\":\"\(code)\"}"))
            XCTAssertTrue(AudioAccountRefreshFailurePolicy.invalidatesAuthorization(status: 403, body: "{\"code\":\"\(code)\"}"))
        }
        for status in [200, 429, 500, 503] {
            XCTAssertFalse(AudioAccountRefreshFailurePolicy.invalidatesAuthorization(status: status, body: "{\"code\":\"session_expired\"}"))
        }
        for body in [nil, "offline", "{\"message\":\"session_expired\"}", "{\"code\":\"bad_json\"}"] {
            XCTAssertFalse(AudioAccountRefreshFailurePolicy.invalidatesAuthorization(status: 400, body: body))
        }
    }

    func testExpiredJWTStillIdentifiesPublishedAccountForExistingOfflineEvidence() throws {
        let claims = Data(#"{"sub":"user","exp":1,"app_metadata":{"tenant_id":"tenant"}}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let session = AuthSession(accessToken: "header.\(claims).signature", refreshToken: nil,
            userIdentifier: "user", nebulaId: nil, displayName: "Test", avatarURL: nil, issuedAt: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(session.isAuthenticatedForProtectedServices)
        let identity = try CrossNetworkTenantIdentifierPolicy.resolveAuthenticatedIdentity(
            accessToken: session.accessToken, explicitTenantID: nil,
            sessionTenantID: nil, sessionUserIdentifier: session.userIdentifier)
        XCTAssertEqual(identity.tenantID, "tenant")
        XCTAssertEqual(identity.userID, "user")
        // This only permits looking up finite evidence; no expired token is sent
        // to issue a new grant, and no JWT claim is itself membership evidence.
    }

    func testOfflineReconnectReusesOriginalEvidenceWithoutAnotherGET() async throws {
        let fixture = try Fixture()
        var gets = 0
        let provider = fixture.provider { _, binding in
            gets += 1; XCTAssertEqual(binding, fixture.binding)
            return fixture.response()
        }
        let firstChannel = fixture.channel()
        let first = try await provider.lease(for: firstChannel)
        firstChannel.close()
        XCTAssertFalse(first.isCurrent)
        fixture.clock.advance(500_000)
        let reconnected = try await provider.lease(for: fixture.channel())
        XCTAssertEqual(gets, 1)
        XCTAssertEqual(first.evidence.id, reconnected.evidence.id)
        XCTAssertEqual(first.evidence.expiresAtMonotonic, reconnected.evidence.expiresAtMonotonic)
        XCTAssertTrue(reconnected.isCurrent)
    }

    func testExpiryAndClockRollbackCannotBecomeNewOfflineValidity() async throws {
        for rollback in [false, true] {
            let fixture = try Fixture()
            var gets = 0
            let provider = fixture.provider { _, _ in
                gets += 1
                if gets > 1 { throw URLError(.notConnectedToInternet) }
                return fixture.response()
            }
            let lease = try await provider.lease(for: fixture.channel())
            fixture.clock.advance(rollback ? -1 : 3_600_000)
            XCTAssertFalse(lease.isCurrent)
            do { _ = try await provider.lease(for: fixture.channel()); XCTFail("Expired evidence reused") }
            catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
            fixture.clock.advance(rollback ? 1 : -3_600_000)
            XCTAssertFalse(lease.isCurrent)
            XCTAssertEqual(gets, 2)
        }
    }

    func testRemovalDuringGETCannotBeUndoneByLatePositiveResponse() async throws {
        let fixture = try Fixture()
        let gate = ResponseGate()
        let provider = fixture.provider { _, _ in try await gate.wait() }
        let task = Task { try await provider.lease(for: fixture.channel()) }
        await gate.waitUntilStarted()
        try await fixture.remove(provider)
        gate.complete(.success(fixture.response()))
        do { _ = try await task.value; XCTFail("Revocation lost") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
    }

    func testRegistryGETStartedBeforeFirstLeaseStillContradictsPendingPublication() async throws {
        let fixture = try Fixture()
        let gate = ResponseGate()
        let provider = fixture.provider { _, _ in try await gate.wait() }
        // Presence captured this account before there were entries or a pending audio GET.
        let observedContext = fixture.context
        let startedWall = fixture.clock.wall, startedMonotonic = fixture.clock.monotonic
        let registryGate = ResponseGate()
        let registry = Task {
            try await provider.observeRequest(context: observedContext) { observation in
                let response = try await registryGate.wait()
                try await provider.observeFreshRegistry(response, context: observedContext,
                    caller: fixture.local, startedWall: startedWall, receivedWall: fixture.clock.wall,
                    startedMonotonic: startedMonotonic, receivedMonotonic: fixture.clock.monotonic,
                    observation: observation)
            }
        }
        await registryGate.waitUntilStarted()
        let task = Task { try await provider.lease(for: fixture.channel()) }
        await gate.waitUntilStarted()
        registryGate.complete(.success(fixture.response(includePeer: false)))
        try await registry.value
        gate.complete(.success(fixture.response()))
        do { _ = try await task.value; XCTFail("Earlier registry request lost its negative observation") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
    }

    func testAccountChangeAndClosedChannelRejectLatePositiveGET() async throws {
        for accountChange in [true, false] {
            let fixture = try Fixture()
            let gate = ResponseGate()
            let provider = fixture.provider { _, _ in try await gate.wait() }
            let channel = fixture.channel()
            let task = Task { try await provider.lease(for: channel) }
            await gate.waitUntilStarted()
            if accountChange { fixture.context.authorization.revoke() } else { channel.close() }
            gate.complete(.success(fixture.response()))
            do { _ = try await task.value; XCTFail("Stale owner accepted") }
            catch {
                if accountChange { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
                else { XCTAssertEqual(error as? P2PAudioTransportError, .closed) }
            }
        }
    }

    func testCancellationRejectsNonCooperativeLateGETAndReleasesRequestSlot() async throws {
        let fixture = try Fixture()
        let gate = ResponseGate()
        var gets = 0
        let provider = fixture.provider { _, _ in
            gets += 1
            return gets == 1 ? try await gate.wait() : fixture.response()
        }
        let task = Task { try await provider.lease(for: fixture.channel()) }
        await gate.waitUntilStarted()
        task.cancel()
        gate.complete(.success(fixture.response()))
        do { _ = try await task.value; XCTFail("Cancelled request published") }
        catch { XCTAssertTrue(error is CancellationError) }
        let lease = try await provider.lease(for: fixture.channel())
        XCTAssertTrue(lease.isCurrent)
        XCTAssertEqual(gets, 2)
    }

    func testNegativeWholeListRevokesOtherLeaseEvenIfSelectedPairIsDenied() async throws {
        let fixture = try Fixture()
        let secondPeer = try AudioProtocolIdentity(deviceID: "audio-third-device-0003", algorithm: .ed25519,
                                                   fingerprint: String(repeating: "c", count: 64))
        var gets = 0
        let provider = fixture.provider { _, _ in
            gets += 1
            return gets == 1 ? fixture.response() : fixture.response(includePeer: false)
        }
        let first = try await provider.lease(for: fixture.channel())
        do { _ = try await provider.lease(for: fixture.channel(peer: secondPeer)); XCTFail("Missing selected peer") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
        XCTAssertFalse(first.isCurrent)
    }

    func testCompletedRegistryGETRevokesOtherLeaseAfterRequesterClosesOrCancels() async throws {
        for cancel in [false, true] {
            let fixture = try Fixture()
            let gate = ResponseGate()
            var gets = 0
            let provider = fixture.provider { _, _ in
                gets += 1
                return gets == 1 ? fixture.response() : try await gate.wait()
            }
            let existing = try await provider.lease(for: fixture.channel())
            let requester = fixture.channel()
            let task = Task { try await provider.lease(for: requester, refresh: true) }
            await gate.waitUntilStarted()
            if cancel { task.cancel() } else { requester.close() }
            gate.complete(.success(fixture.response(includePeer: false)))
            do { _ = try await task.value; XCTFail("Closed/cancelled requester issued evidence") }
            catch {
                if cancel { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertEqual(error as? P2PAudioTransportError, .closed) }
            }
            XCTAssertFalse(existing.isCurrent, "Completed account observation was lost with its requesting channel")
        }
    }

    func testTruncatedListOnlyRevokesExplicitInactiveIdentityAndNeverRenews() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider { _, _ in fixture.response() }
        let lease = try await provider.lease(for: fixture.channel())
        try await fixture.observe(provider, response: fixture.response(includePeer: false, truncated: true))
        XCTAssertTrue(lease.isCurrent)
        try await fixture.observe(provider, response: fixture.response(peerStatus: "frozen", truncated: true))
        XCTAssertFalse(lease.isCurrent)
        try await fixture.observe(provider, response: fixture.response())
        XCTAssertFalse(lease.isCurrent)
    }

    func testMalformedStaleAndOtherScopeObservationsCannotRevoke() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider { _, _ in fixture.response() }
        let lease = try await provider.lease(for: fixture.channel())
        do { try await fixture.observe(provider, response: fixture.response(includePeer: false).scoped(to: "other/user")); XCTFail("Other scope accepted") }
        catch { XCTAssertTrue(error is AudioMembershipError) }
        fixture.clock.advance(30_001)
        do { try await fixture.observe(provider, response: fixture.response(includePeer: false, generated: 1_000_000)); XCTFail("Stale observation accepted") }
        catch { XCTAssertTrue(error is AudioMembershipError) }
        XCTAssertTrue(lease.isCurrent)
    }

    func testOnlyOnePendingGETAndFailureDoesNotDestroyUnrelatedLease() async throws {
        let fixture = try Fixture()
        let gate = ResponseGate()
        var gets = 0
        let provider = fixture.provider { _, _ in
            gets += 1
            if gets == 1 { return fixture.response() }
            return try await gate.wait()
        }
        let lease = try await provider.lease(for: fixture.channel())
        let task = Task { try await provider.lease(for: fixture.channel(), refresh: true) }
        await gate.waitUntilStarted()
        do { _ = try await provider.lease(for: fixture.channel(), refresh: true); XCTFail("Parallel GET") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .requestInProgress) }
        gate.complete(.failure(URLError(.notConnectedToInternet)))
        do { _ = try await task.value; XCTFail("Network failure hidden") }
        catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
        XCTAssertTrue(lease.isCurrent)
        XCTAssertEqual(gets, 2)
    }

    func testExplicitRenewalRevokesPreviouslyIssuedConsumers() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider { _, _ in fixture.response() }
        let first = try await provider.lease(for: fixture.channel())
        fixture.clock.advance(100)
        let second = try await provider.lease(for: fixture.channel(), refresh: true)
        XCTAssertFalse(first.isCurrent)
        XCTAssertTrue(second.isCurrent)
        XCTAssertNotEqual(first.evidence.id, second.evidence.id)
    }

    func testFreshContinuationPreservesOnlyTheNamedConnectionAndItsNewDeadline() async throws {
        let fixture = try Fixture()
        var gets = 0
        let provider = fixture.provider { _, _ in gets += 1; return fixture.response() }
        let channel = fixture.channel()
        let continuing = try await provider.lease(for: channel)
        let other = try await provider.lease(for: fixture.channel())
        let original = continuing.evidence
        fixture.clock.advance(1_000)
        let renewed = try await provider.renew(for: channel, continuing: continuing)
        XCTAssertTrue(renewed === continuing)
        XCTAssertNotEqual(renewed.evidence.id, original.id)
        XCTAssertEqual(gets, 2)
        XCTAssertTrue(renewed.isCurrent)
        XCTAssertFalse(other.isCurrent)
        fixture.clock.advance(3_599_000)
        XCTAssertTrue(renewed.isCurrent)
        fixture.clock.advance(1_000)
        XCTAssertEqual(renewed.failure, .expired)
    }

    func testContinuationRejectsAnotherConnectionOwnerBeforeAnotherGET() async throws {
        let fixture = try Fixture()
        var gets = 0
        let provider = fixture.provider { _, _ in gets += 1; return fixture.response() }
        let channel = fixture.channel()
        let lease = try await provider.lease(for: channel)
        fixture.clock.advance(1_000)
        do { _ = try await provider.renew(for: fixture.channel(), continuing: lease); XCTFail("Different owner renewed") }
        catch { XCTAssertEqual(error as? AudioMembershipError, .invalidIdentity) }
        XCTAssertTrue(lease.isCurrent)
        XCTAssertEqual(gets, 1)
    }

    func testContinuationFailureLeavesOnlyTheOriginalFiniteGrant() async throws {
        let fixture = try Fixture()
        var gets = 0
        let provider = fixture.provider { _, _ in
            gets += 1
            if gets > 1 { throw URLError(.notConnectedToInternet) }
            return fixture.response()
        }
        let channel = fixture.channel()
        let lease = try await provider.lease(for: channel)
        let original = lease.evidence
        fixture.clock.advance(1_000)
        do { _ = try await provider.renew(for: channel, continuing: lease); XCTFail("Offline query accepted") }
        catch let error as AudioMembershipRequestUnavailable {
            XCTAssertEqual((error.underlying as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(lease.evidence, original)
        XCTAssertTrue(lease.isCurrent)
        fixture.clock.advance(3_599_000)
        XCTAssertEqual(lease.failure, .expired)
        do { _ = try await provider.renew(for: channel, continuing: lease); XCTFail("Expired stream revived") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .expired) }
        XCTAssertEqual(gets, 2)
    }

    func testRemovalDuringContinuationCannotBeUndoneByItsLatePositiveGET() async throws {
        let fixture = try Fixture()
        let gate = ResponseGate()
        var gets = 0
        let provider = fixture.provider { _, _ in
            gets += 1
            return gets == 1 ? fixture.response() : try await gate.wait()
        }
        let channel = fixture.channel()
        let lease = try await provider.lease(for: channel)
        let original = lease.evidence
        fixture.clock.advance(1_000)
        let task = Task { try await provider.renew(for: channel, continuing: lease) }
        await gate.waitUntilStarted()
        try await fixture.remove(provider)
        XCTAssertFalse(lease.isCurrent)
        gate.complete(.success(fixture.response()))
        do { _ = try await task.value; XCTFail("Known revocation lost") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
        XCTAssertEqual(lease.evidence, original)
        XCTAssertFalse(lease.isCurrent)
    }

    func testCapacityRejectsNewGrantWithoutEvictingActiveConsumers() async throws {
        let fixture = try Fixture()
        let peers = try (0..<33).map { index in
            try AudioProtocolIdentity(deviceID: "audio-cache-peer-device-\(index)", algorithm: .ed25519,
                                      fingerprint: String(repeating: "d", count: 64))
        }
        let rows = [fixture.row(fixture.local, caller: true, status: "active")]
            + peers.map { fixture.row($0, caller: false, status: "active") }
        let provider = fixture.provider { _, _ in
            AccountDeviceListSnapshot(generatedAtEpochMilliseconds: fixture.clock.wall,
                callerDeviceId: fixture.local.deviceID, truncated: false, devices: rows,
                accountScope: fixture.context.account.serverScope)
        }
        var leases: [AudioMembershipLease] = []
        for peer in peers.prefix(32) { leases.append(try await provider.lease(for: fixture.channel(peer: peer))) }
        do { _ = try await provider.lease(for: fixture.channel(peer: peers[32])); XCTFail("Unbounded cache") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .capacity) }
        XCTAssertTrue(leases.allSatisfy(\.isCurrent))
    }

    func testKnownInactiveCallerRevokesExistingGrantButOtherHTTPFailuresDoNot() async throws {
        for code in ["device_revoked", "registry_unavailable"] {
            let fixture = try Fixture()
            var gets = 0
            let provider = fixture.provider { _, _ in
                gets += 1
                if gets > 1 { throw SignalServerClient.ClientError.serverRejected(403, "{\"error\":\"\(code)\"}") }
                return fixture.response()
            }
            let lease = try await provider.lease(for: fixture.channel())
            do { _ = try await provider.lease(for: fixture.channel(), refresh: true); XCTFail("Rejection hidden") }
            catch { XCTAssertTrue(error is SignalServerClient.ClientError) }
            XCTAssertEqual(lease.isCurrent, code != "device_revoked")
        }
    }

    func testHeartbeatInactive200RevokesCallerAndContradictsPendingPositiveGET() async throws {
        let fixture = try Fixture()
        let gate = ResponseGate()
        var gets = 0
        let provider = fixture.provider { _, _ in
            gets += 1
            return gets == 1 ? fixture.response() : try await gate.wait()
        }
        let response = try heartbeat(#"{"online":true,"persisted":false,"persistReason":"device_not_active"}"#)
        let existing = try await provider.lease(for: fixture.channel())
        let pending = Task { try await provider.lease(for: fixture.channel(), refresh: true) }
        await gate.waitUntilStarted()
        do { try await fixture.observeHeartbeat(provider, response: response) }
        catch {
            gate.complete(.failure(error))
            _ = await pending.result
            throw error
        }
        XCTAssertFalse(existing.isCurrent)
        gate.complete(.success(fixture.response()))
        do { _ = try await pending.value; XCTFail("Heartbeat inactive result was undone by a late positive GET") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
    }

    func testOtherHeartbeatReasonsAndLegacyResponseNeitherRevokeNorRenewEvidence() async throws {
        let fixture = try Fixture()
        var gets = 0
        let provider = fixture.provider { _, _ in gets += 1; return fixture.response() }
        let responses = try [
            #"{"online":true,"persisted":true,"persistReason":"written"}"#,
            #"{"online":true,"persisted":false,"persistReason":"throttled"}"#,
            #"{"online":true,"persisted":false,"persistReason":"registry_unavailable"}"#,
            #"{"online":true,"persisted":false,"persistReason":"registry_not_configured"}"#,
            #"{"online":true,"persisted":false,"persistReason":"future_reason"}"#,
            #"{"online":true}"#,
            #"{"online":true,"persisted":true,"persistReason":"device_not_active"}"#,
            #"{"online":true,"persistReason":"device_not_active"}"#
        ].map { try heartbeat($0) }
        for response in responses {
            try await fixture.observeHeartbeat(provider, response: response)
        }
        XCTAssertEqual(gets, 0, "Heartbeat observations cannot fetch or create membership evidence")
        let lease = try await provider.lease(for: fixture.channel())
        let evidence = lease.evidence
        fixture.clock.advance(100_000)
        for response in responses {
            try await fixture.observeHeartbeat(provider, response: response)
            XCTAssertTrue(lease.isCurrent)
        }
        let reused = try await provider.lease(for: fixture.channel())
        XCTAssertEqual(gets, 1, "Only the actual account GET issues evidence")
        XCTAssertEqual(reused.evidence, evidence, "Heartbeat cannot renew either clock or replace evidence")
    }

    func testHeartbeatAndRemovalFromOldEpochOrAuthorityCannotRevokeCurrentLease() async throws {
        for replaceEpoch in [true, false] {
            let fixture = try Fixture()
            let oldContext = fixture.context
            let current = CurrentAccountContext(oldContext)
            let provider = AudioAccountMembershipProvider(currentContext: { current.value },
                fetch: { _, _ in fixture.response() },
                wall: { fixture.clock.wall }, monotonic: { fixture.clock.monotonic })
            _ = try await provider.lease(for: fixture.channel())
            let account: AudioAccountIdentity
            if replaceEpoch { account = oldContext.account }
            else {
                account = try AudioAccountIdentity(authority: "https://replacement.example.invalid",
                    tenantID: oldContext.account.tenantID, userID: oldContext.account.userID)
            }
            current.value = AudioAccountContext(
                authorization: replaceEpoch ? AccountAudioAuthorization() : oldContext.authorization,
                account: account)
            let currentLease = try await provider.lease(for: fixture.channel())
            let response = try heartbeat(#"{"online":true,"persisted":false,"persistReason":"device_not_active"}"#)
            do { try await fixture.observeHeartbeat(provider, response: response, context: oldContext); XCTFail("Old heartbeat accepted") }
            catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
            XCTAssertTrue(currentLease.isCurrent)
            do { try await fixture.remove(provider, context: oldContext); XCTFail("Old removal accepted") }
            catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
            XCTAssertTrue(currentLease.isCurrent)
            // A matching context's confirmed removal still takes effect.
            try await fixture.remove(provider, context: current.value)
            XCTAssertFalse(currentLease.isCurrent)
        }
    }

    func testCompletedInactiveHeartbeatStillRevokesWhenItsPresentationTaskWasCancelled() async throws {
        let fixture = try Fixture()
        let provider = fixture.provider { _, _ in fixture.response() }
        let existing = try await provider.lease(for: fixture.channel())
        let gate = HeartbeatResponseGate()
        let response = try heartbeat(#"{"online":true,"persisted":false,"persistReason":"device_not_active"}"#)
        let task = Task {
            try await provider.observeRequest(context: fixture.context) { observation in
                let response = try await gate.wait()
                // Completed negative facts survive presentation cancellation.
                try await provider.observeHeartbeat(response, context: fixture.context,
                    caller: fixture.local, observation: observation)
            }
        }
        await gate.waitUntilStarted()
        task.cancel()
        gate.complete(response)
        try await task.value
        XCTAssertFalse(existing.isCurrent)
    }

    private func heartbeat(_ json: String) throws -> SignalServerClient.PresenceRegisterResponseBody {
        try JSONDecoder().decode(SignalServerClient.PresenceRegisterResponseBody.self, from: Data(json.utf8))
    }
}

@MainActor
final class AudioMembershipRenewalTests: XCTestCase {
    func testOnlineRenewalCommitsFreshEvidenceBeforeTheOriginalExpiry() async throws {
        let f = try Fixture(), observations = RenewalObservations()
        var gets = 0
        let provider = f.provider { _, _ in gets += 1; return f.response() }
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        let original = lease.evidence
        let task = Task { await f.renewal(provider, channel, lease, observations).run() }
        defer { task.cancel() }
        try await until { f.clock.sleepers == 1 }
        f.clock.advance(3_480_000)
        try await until { observations.count(.waiting) == 2 && f.clock.sleepers == 1 }
        XCTAssertEqual(gets, 2)
        XCTAssertGreaterThan(lease.evidence.expiresAtMilliseconds, original.expiresAtMilliseconds)
        f.clock.advance(120_000)
        XCTAssertTrue(lease.isCurrent)
        task.cancel(); await task.value
        XCTAssertEqual(f.clock.sleepers, 0)
        XCTAssertEqual(gets, 2)
    }

    func testExplicitOfflineModeMakesNoRenewalRequest() async throws {
        let f = try Fixture(), observations = RenewalObservations()
        var gets = 0
        let provider = f.provider { _, _ in gets += 1; return f.response() }
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        let original = lease.evidence
        await f.renewal(provider, channel, lease, observations).run(allowNetwork: false)
        XCTAssertTrue(observations.values.isEmpty)
        XCTAssertEqual(gets, 1)
        XCTAssertEqual(f.clock.sleepers, 0)
        f.clock.advance(3_600_000)
        XCTAssertEqual(lease.failure, .expired)
        XCTAssertEqual(lease.evidence, original)
    }

    func testTemporaryNetworkFailuresUseOnlyThreeSpacedAttemptsAndKeepExpiry() async throws {
        let f = try Fixture(), observations = RenewalObservations()
        var gets: [Int64] = []
        let provider = f.provider { _, _ in
            gets.append(f.clock.wall)
            if gets.count > 1 { throw URLError(.notConnectedToInternet) }
            return f.response()
        }
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        let original = lease.evidence
        let task = Task { await f.renewal(provider, channel, lease, observations).run() }
        defer { task.cancel() }
        try await until { f.clock.sleepers == 1 }
        f.clock.advance(3_480_000)
        try await until { observations.count(.retryPending) == 1 && f.clock.sleepers == 1 }
        f.clock.advance(45_000)
        try await until { observations.count(.retryPending) == 2 && f.clock.sleepers == 1 }
        f.clock.advance(35_000)
        await task.value
        XCTAssertEqual(gets, [1_000_000, 4_480_000, 4_525_000, 4_560_000])
        XCTAssertEqual(observations.values.last?.state, .unavailable)
        XCTAssertTrue(observations.values.last?.failure is AudioMembershipRequestUnavailable)
        XCTAssertEqual(lease.evidence, original)
        XCTAssertTrue(lease.isCurrent)
        f.clock.advance(40_000)
        XCTAssertEqual(lease.failure, .expired)
    }

    func testLateAdmissionSkipsMissedSlotsWithoutBurstingRetries() async throws {
        let f = try Fixture(), observations = RenewalObservations()
        var gets = 0
        let provider = f.provider { _, _ in
            gets += 1
            if gets > 1 { throw URLError(.cannotFindHost) }
            return f.response()
        }
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        f.clock.advance(3_550_000)
        let task = Task { await f.renewal(provider, channel, lease, observations).run() }
        defer { task.cancel() }
        try await until { observations.count(.retryPending) == 1 && f.clock.sleepers == 1 }
        f.clock.advance(10_000)
        await task.value
        XCTAssertEqual(gets, 3)
        XCTAssertEqual(observations.values.last?.state, .unavailable)
        XCTAssertTrue(lease.isCurrent)
    }

    func testNegativeObservationBetweenAttemptsPreventsAnotherGET() async throws {
        let f = try Fixture(), observations = RenewalObservations()
        var gets = 0
        let provider = f.provider { _, _ in
            gets += 1
            if gets > 1 { throw URLError(.networkConnectionLost) }
            return f.response()
        }
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        let task = Task { await f.renewal(provider, channel, lease, observations).run() }
        defer { task.cancel() }
        try await until { f.clock.sleepers == 1 }
        f.clock.advance(3_480_000)
        try await until { observations.count(.retryPending) == 1 && f.clock.sleepers == 1 }
        try await f.remove(provider)
        f.clock.advance(45_000)
        await task.value
        XCTAssertEqual(gets, 2)
        XCTAssertEqual(observations.values.last?.state, .failed)
        XCTAssertFalse(lease.isCurrent)
    }

    func testTLSAndUnclassifiedFailuresRetireTheConsumerWithoutRetries() async throws {
        for failure in [URLError(.secureConnectionFailed), NSError(domain: NSCocoaErrorDomain, code: 513)] as [Error] {
            let f = try Fixture(), observations = RenewalObservations()
            var gets = 0
            let provider = f.provider { _, _ in
                gets += 1
                if gets > 1 { throw failure }
                return f.response()
            }
            let channel = f.channel(), lease = try await provider.lease(for: channel)
            let task = Task { await f.renewal(provider, channel, lease, observations).run() }
            defer { task.cancel() }
            try await until { f.clock.sleepers == 1 }
            f.clock.advance(3_480_000)
            await task.value
            XCTAssertEqual(gets, 2)
            XCTAssertEqual(observations.values.last?.state, .failed)
            let observed = try XCTUnwrap(observations.values.last?.failure) as NSError
            XCTAssertEqual(observed.domain, (failure as NSError).domain)
            XCTAssertEqual(observed.code, (failure as NSError).code)
            XCTAssertFalse(lease.isCurrent)
        }
    }

    func testSuccessfulReturnWithoutFreshEvidenceCannotExtendPlayback() async throws {
        let f = try Fixture(), observations = RenewalObservations()
        let provider = f.provider { _, _ in f.response() }
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        let original = lease.evidence
        let runner = AudioMembershipRenewal(lease: lease, renew: {},
            observe: { await observations.append($0) }, wall: { f.clock.wall }, monotonic: { f.clock.monotonic },
            sleep: { try await f.clock.sleep($0) })
        let task = Task { await runner.run() }
        defer { task.cancel() }
        try await until { f.clock.sleepers == 1 }
        f.clock.advance(3_480_000)
        await task.value
        XCTAssertEqual(observations.values.last?.failure as? AudioMembershipRenewalError, .missingFreshEvidence)
        XCTAssertEqual(lease.evidence, original)
        XCTAssertFalse(lease.isCurrent)
    }

    func testCancellationJoinsLateGETWithoutRevokingOtherwiseValidEvidence() async throws {
        let f = try Fixture(), observations = RenewalObservations(), gate = ResponseGate()
        defer { gate.cancelPending() }
        var gets = 0
        let provider = f.provider { _, _ in
            gets += 1
            return gets == 1 ? f.response() : try await gate.wait()
        }
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        let original = lease.evidence
        let task = Task { await f.renewal(provider, channel, lease, observations).run() }
        defer { task.cancel() }
        try await until { f.clock.sleepers == 1 }
        f.clock.advance(3_480_000)
        await gate.waitUntilStarted()
        task.cancel()
        try await until { f.clock.sleepers == 0 }
        XCTAssertTrue(lease.isCurrent)
        gate.complete(.success(f.response()))
        await task.value
        XCTAssertEqual(lease.evidence, original)
        XCTAssertTrue(lease.isCurrent)
        XCTAssertEqual(observations.count(.failed), 0)
    }

    func testOverallDeadlineRevokesBeforeWaitingForNoncooperativeCleanup() async throws {
        let f = try Fixture(), observations = RenewalObservations(), gate = ResponseGate()
        defer { gate.cancelPending() }
        var gets = 0
        let provider = f.provider { _, _ in
            gets += 1
            return gets == 1 ? f.response() : try await gate.wait()
        }
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        let original = lease.evidence
        let task = Task { await f.renewal(provider, channel, lease, observations).run() }
        defer { task.cancel() }
        try await until { f.clock.sleepers == 1 }
        f.clock.advance(3_480_000)
        await gate.waitUntilStarted()
        try await until { f.clock.sleepers == 1 }
        f.clock.advance(35_000)
        try await until { !lease.isCurrent }
        XCTAssertEqual(observations.count(.failed), 0) // The provider is still owned and joined.
        gate.complete(.success(f.response()))
        await task.value
        XCTAssertEqual(observations.values.last?.failure as? AudioMembershipRenewalError, .deadlineExceeded)
        XCTAssertEqual(lease.evidence, original)
        XCTAssertFalse(lease.isCurrent)
    }

    func testRetryClassificationExcludesSecurityMalformedAndUnknownFailures() {
        for code in [URLError.Code.secureConnectionFailed, .serverCertificateUntrusted, .cancelled, .badURL] {
            XCTAssertFalse(AudioMembershipRequestFailurePolicy.isTemporaryNetworkError(URLError(code)))
        }
        XCTAssertTrue(AudioMembershipRequestFailurePolicy.isTemporaryNetworkError(URLError(.timedOut)))
        for status in [401, 403, 404, 409, 422] {
            XCTAssertFalse(AudioMembershipRequestFailurePolicy.isTemporaryHTTPStatus(status, errorCode: nil))
        }
        for status in [429, 500, 502, 503, 504] {
            XCTAssertTrue(AudioMembershipRequestFailurePolicy.isTemporaryHTTPStatus(status, errorCode: nil))
            XCTAssertFalse(AudioMembershipRequestFailurePolicy.isTemporaryHTTPStatus(status, errorCode: "device_revoked"))
        }
    }

    func testTemporaryLookingProtectedWriteFailureIsNeverARequestRetry() async throws {
        let f = try Fixture(), boot = UUID()
        let storage = RenewalCheckpointBackend()
        let provider = AudioAccountMembershipProvider(currentContext: { f.context }, fetch: { _, _ in f.response() },
            wall: { f.clock.wall }, monotonic: { f.clock.monotonic },
            persistence: AudioMembershipPersistence(bootSessionID: { boot }, load: { _ in storage.record },
                save: { _, revision, bytes in
                    XCTAssertEqual(revision, storage.record.revision)
                    if storage.failWrite { throw URLError(.networkConnectionLost) }
                    storage.record = .init(revision: UUID(), checkpoint: bytes)
                    return storage.record
                }, beginObservation: { _ in try storage.begin() }))
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        let original = lease.evidence
        f.clock.advance(1_000); storage.failWrite = true
        do { _ = try await provider.renew(for: channel, continuing: lease); XCTFail("Storage failure hidden") }
        catch {
            XCTAssertFalse(error is AudioMembershipRequestUnavailable)
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost)
        }
        XCTAssertEqual(lease.evidence, original)
        XCTAssertFalse(lease.isCurrent)
    }

    func testMissingRefreshCredentialCannotRenewButKeepsOriginalOfflineExpiry() async throws {
        let f = try Fixture()
        var gets = 0
        let provider = f.provider { _, _ in
            gets += 1
            if gets > 1 { throw AuthenticationService.AuthenticationError.refreshCredentialUnavailable }
            return f.response()
        }
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        let original = lease.evidence
        f.clock.advance(1_000)
        do { _ = try await provider.renew(for: channel, continuing: lease); XCTFail("Missing credential renewed evidence") }
        catch let error as AudioMembershipRequestUnavailable {
            guard case AuthenticationService.AuthenticationError.refreshCredentialUnavailable = error.underlying else {
                return XCTFail("Local credential failure lost its type")
            }
        }
        XCTAssertEqual(lease.evidence, original)
        XCTAssertTrue(lease.isCurrent)
        f.clock.advance(3_599_000)
        XCTAssertEqual(lease.failure, .expired)
        XCTAssertEqual(gets, 2)
    }

    func testFreshEvidenceContinuesOnlyTheAlreadyApprovedFileTransfer() async throws {
        let f = try Fixture()
        let provider = f.provider { _, _ in f.response() }
        let channel = f.channel(), lease = try await provider.lease(for: channel)
        let original = lease.evidence
        let offer = AudioStreamingMessage(streamID: UUID(), body: .fileOffer(transferID: UUID(),
            length: 128, sha256: Data(repeating: 0x27, count: 32)))
        let request = try AudioPlaybackApprovalRequest(ownerID: channel.ownerID, offer: offer,
            membership: original, outputEndpointUID: "renewal-test-output")
        let approvals = try AudioPlaybackApprovalService(decisionTimeout: .seconds(5))
        let pending = Task { try await approvals.requestApproval(request, isCurrent: { lease.isCurrent }) }
        defer { pending.cancel() }
        try await until { approvals.pendingRequest != nil }
        XCTAssertTrue(approvals.resolve(request, allowOnce: true))
        let permission = try await pending.value
        let transfer = try AudioOriginalFileTransfer(channel: channel, offer: offer, membership: lease,
            permission: permission, endpoint: "renewal-test-output")
        f.clock.advance(1_000)
        _ = try await provider.renew(for: channel, continuing: lease)
        XCTAssertNotEqual(lease.evidence.id, original.id)
        XCTAssertEqual(permission.request.membershipID, original.id)
        XCTAssertTrue(permission.isApproved)
        XCTAssertNoThrow(try transfer.requireAuthorization())
        XCTAssertThrowsError(try AudioOriginalFileTransfer(channel: channel, offer: offer, membership: lease,
            permission: permission, endpoint: "renewal-test-output")) {
            XCTAssertEqual($0 as? AudioOriginalFileTransferError, .invalidPermission)
        }
        permission.revoke()
        XCTAssertThrowsError(try transfer.requireAuthorization())
        let cleanup = await transfer.close()
        XCTAssertEqual(cleanup.state, .released)
    }

    private func until(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate() {
            if ContinuousClock.now >= deadline { throw URLError(.timedOut) }
            await Task.yield()
        }
    }
}

@MainActor
private final class RenewalObservations {
    var values: [AudioMembershipRenewalUpdate] = []
    func append(_ value: AudioMembershipRenewalUpdate) { values.append(value) }
    func count(_ state: AudioMembershipRenewalState) -> Int { values.filter { $0.state == state }.count }
}

@MainActor
private final class RenewalCheckpointBackend {
    var record = AudioMembershipPersistenceSnapshot(revision: UUID(), checkpoint: nil)
    var failWrite = false
    private var observations = Set<UUID>()
    func begin() throws -> AudioMembershipPersistenceObservation {
        let id = UUID()
        observations.insert(id)
        return AudioMembershipPersistenceObservation(finish: { revision, update in
            guard self.observations.remove(id) != nil, revision == self.record.revision else {
                throw ProtectedAccountSessionError.changed
            }
            if self.failWrite { throw URLError(.networkConnectionLost) }
            if case .replace(let bytes) = update {
                self.record = .init(revision: UUID(), checkpoint: bytes)
            }
            return self.record
        }, abandon: { self.observations.remove(id) })
    }
}

@MainActor
private final class CurrentAccountContext {
    var value: AudioAccountContext
    init(_ value: AudioAccountContext) { self.value = value }
}

@MainActor
private final class HeartbeatResponseGate {
    private var continuation: CheckedContinuation<SignalServerClient.PresenceRegisterResponseBody, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async throws -> SignalServerClient.PresenceRegisterResponseBody {
        try await withCheckedThrowingContinuation {
            continuation = $0; started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func complete(_ response: SignalServerClient.PresenceRegisterResponseBody) {
        precondition(continuation != nil)
        continuation?.resume(returning: response); continuation = nil
    }
}

@MainActor
private final class ResponseGate {
    private var continuation: CheckedContinuation<AccountDeviceListSnapshot, Error>?
    private var started: CheckedContinuation<Void, Never>?
    func wait() async throws -> AccountDeviceListSnapshot {
        try await withCheckedThrowingContinuation {
            continuation = $0; started?.resume(); started = nil
        }
    }
    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func complete(_ result: Result<AccountDeviceListSnapshot, Error>) {
        precondition(continuation != nil)
        continuation?.resume(with: result); continuation = nil
    }
    func cancelPending() { continuation?.resume(throwing: CancellationError()); continuation = nil }
}

@MainActor
private struct Fixture {
    let binding: ProtocolIdentityBinding
    let local: AudioProtocolIdentity
    let peer: AudioProtocolIdentity
    let context: AudioAccountContext
    let clock = TestClock()
    init() throws {
        binding = try .init(deviceId: "audio-local-device-0001", protocolSigningAlgorithm: .ed25519,
                            protocolPublicKeyBytes: Data(repeating: 0x47, count: 32))
        local = try .init(binding)
        peer = try .init(deviceID: "audio-peer-device-0002", algorithm: .ed25519, fingerprint: String(repeating: "b", count: 64))
        context = AudioAccountContext(authorization: AccountAudioAuthorization(), account: try .init(
            authority: "https://signal.example.invalid", tenantID: "tenant", userID: "user"))
    }
    func channel(peer: AudioProtocolIdentity? = nil) -> P2PAudioChannel {
        let mailbox = P2PAudioMailbox()
        return P2PAudioChannel(mailbox: mailbox, remoteIdentity: peer ?? self.peer,
            localIdentityBinding: binding, controlTransport: .network, validateOwner: {}, send: { _, effect in try effect?() }, close: { mailbox.finish(.closed) })
    }
    func provider(fetch: @escaping @MainActor (AudioAccountContext, ProtocolIdentityBinding) async throws -> AccountDeviceListSnapshot)
        -> AudioAccountMembershipProvider {
        AudioAccountMembershipProvider(currentContext: { context }, fetch: fetch,
            wall: { clock.wall }, monotonic: { clock.monotonic })
    }
    func response(includePeer: Bool = true, peerStatus: String = "active", truncated: Bool = false, generated: Int64? = nil)
        -> AccountDeviceListSnapshot {
        var rows = [row(local, caller: true, status: "active")]
        if includePeer { rows.append(row(peer, caller: false, status: peerStatus)) }
        return .init(generatedAtEpochMilliseconds: generated ?? clock.wall, callerDeviceId: local.deviceID,
                     truncated: truncated, devices: rows, accountScope: context.account.serverScope)
    }
    func row(_ identity: AudioProtocolIdentity, caller: Bool, status: String) -> AccountDeviceRecord {
        .init(deviceId: identity.deviceID, deviceName: nil, status: status,
              protocolSigningAlgorithm: identity.algorithm.rawValue, protocolPublicKeyFingerprint: identity.fingerprint,
              platformRawValue: nil, deviceModel: nil, osVersion: nil, appVersion: nil, lanAddresses: [], publicAddress: nil,
              capabilities: [], registeredAtEpochMilliseconds: nil, lastSeenAtEpochMilliseconds: nil,
              presenceUpdatedAtEpochMilliseconds: nil, online: false, isCaller: caller)
    }
    func observe(_ provider: AudioAccountMembershipProvider, response: AccountDeviceListSnapshot) async throws {
        try await provider.observeRequest(context: context) { observation in
            try await provider.observeFreshRegistry(response, context: context, caller: local,
                startedWall: clock.wall, receivedWall: clock.wall,
                startedMonotonic: clock.monotonic, receivedMonotonic: clock.monotonic, observation: observation)
        }
    }
    func remove(_ provider: AudioAccountMembershipProvider, context: AudioAccountContext? = nil) async throws {
        let captured = context ?? self.context
        try await provider.observeRequest(context: captured, allowTemporaryFailure: false) { observation in
            try await provider.revoke(identity: peer, context: captured, observation: observation)
        }
    }
    func observeHeartbeat(_ provider: AudioAccountMembershipProvider,
                          response: SignalServerClient.PresenceRegisterResponseBody,
                          context: AudioAccountContext? = nil) async throws {
        let captured = context ?? self.context
        try await provider.observeRequest(context: captured) { observation in
            try await provider.observeHeartbeat(response, context: captured, caller: local, observation: observation)
        }
    }
    func renewal(_ provider: AudioAccountMembershipProvider, _ channel: P2PAudioChannel,
                 _ lease: AudioMembershipLease, _ observations: RenewalObservations) -> AudioMembershipRenewal {
        AudioMembershipRenewal(lease: lease, renew: {
            _ = try await provider.renew(for: channel, continuing: lease)
        }, observe: { await observations.append($0) }, wall: { clock.wall }, monotonic: { clock.monotonic },
            sleep: { try await clock.sleep($0) })
    }
}

private final class TestClock: Sendable {
    private struct Waiter { let deadline: ContinuousClock.Instant; let continuation: CheckedContinuation<Void, Error> }
    private struct State {
        var wall: Int64 = 1_000_000
        var monotonic = ContinuousClock.now
        var waiters: [UUID: Waiter] = [:]
    }
    private let value = OSAllocatedUnfairLock(initialState: State())
    var wall: Int64 { value.withLock { $0.wall } }
    var monotonic: ContinuousClock.Instant { value.withLock { $0.monotonic } }
    var sleepers: Int { value.withLock { $0.waiters.count } }
    func advance(_ milliseconds: Int64) {
        let ready = value.withLock { state in
            state.wall += milliseconds
            state.monotonic = state.monotonic.advanced(by: .milliseconds(milliseconds))
            let ready = state.waiters.filter { $0.value.deadline <= state.monotonic }
            for id in ready.keys { state.waiters.removeValue(forKey: id) }
            return Array(ready.values)
        }
        ready.forEach { $0.continuation.resume() }
    }
    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        if duration <= .zero { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = value.withLock { state in
                    if Task.isCancelled { return true }
                    state.waiters[id] = Waiter(deadline: state.monotonic.advanced(by: duration), continuation: continuation)
                    return false
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = value.withLock { $0.waiters.removeValue(forKey: id) }
            waiter?.continuation.resume(throwing: CancellationError())
        }
    }
}
