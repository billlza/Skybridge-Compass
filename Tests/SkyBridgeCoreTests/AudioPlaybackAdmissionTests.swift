import Foundation
import Combine
import XCTest
import os
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

@MainActor
final class AudioPlaybackAdmissionTests: XCTestCase {
    func testOpusPermissionBindsExactSourceProfileAndCannotAuthorizeStrictPCM() async throws {
        let fixture = try AdmissionFixture(), service = try AudioPlaybackApprovalService()
        let offer = AudioStreamingMessage(streamID: UUID(), body: .opusOffer(source: .originalFile,
            format: try .init(channels: 2, bitrate: 192_000)))
        let request = try AudioPlaybackApprovalRequest(ownerID: UUID(), offer: offer,
            membership: fixture.evidence(), outputEndpointUID: "selected-output")
        let task = Task { try await service.requestApproval(request, isCurrent: { true }) }
        try await waitForPrompt(service)
        XCTAssertTrue(service.resolve(request, allowOnce: true))
        let permission = try await task.value
        XCTAssertTrue(permission.approves(ownerID: request.ownerID, streamID: request.streamID,
            source: request.source, outputEndpointUID: request.outputEndpointUID))
        let changed: [AudioPlaybackSource] = [
            .opus(source: .systemCapture, format: try .init(channels: 2, bitrate: 192_000)),
            .opus(source: .originalFile, format: try .init(channels: 1, bitrate: 192_000)),
            .opus(source: .originalFile, format: try .init(channels: 2, bitrate: 128_000)),
            try fixture.request().source,
        ]
        for source in changed {
            XCTAssertFalse(permission.approves(ownerID: request.ownerID, streamID: request.streamID,
                source: source, outputEndpointUID: request.outputEndpointUID))
        }
        XCTAssertThrowsError(try AudioPlaybackSource(offer: .init(streamID: offer.streamID, body: .opusConfiguration(preSkipFrames: 312))))
        permission.revoke()
        XCTAssertFalse(permission.approves(ownerID: request.ownerID, streamID: request.streamID,
            source: request.source, outputEndpointUID: request.outputEndpointUID))
    }

    func testFreshMembershipRequiresBothExactActiveIdentitiesButNotPresence() throws {
        let fixture = try AdmissionFixture()
        let evidence = try fixture.evidence()
        XCTAssertEqual(evidence.localIdentity, fixture.local)
        XCTAssertEqual(evidence.peerIdentity, fixture.peer)
        XCTAssertEqual(evidence.expiresAtMilliseconds, fixture.time + 3_600_000)
        try evidence.validate(account: fixture.account, local: fixture.local, peer: fixture.peer,
                              nowMilliseconds: fixture.time + 3_599_999)
        for status in ["pending", "frozen", "revoked", "unknown"] {
            XCTAssertThrowsError(try fixture.evidence(peerStatus: status))
            XCTAssertThrowsError(try fixture.evidence(localStatus: status))
        }
        XCTAssertThrowsError(try fixture.evidence(peerFingerprint: String(repeating: "c", count: 64)))
        XCTAssertThrowsError(try fixture.evidence(peerAlgorithm: "ml-dsa-65"))
    }

    func testWrongAccountIncompleteAndMissingRecordsCannotIssueEvidence() throws {
        let fixture = try AdmissionFixture()
        XCTAssertThrowsError(try fixture.evidence(scope: "another/user"))
        XCTAssertThrowsError(try fixture.evidence(truncated: true))
        XCTAssertThrowsError(try fixture.evidence(includePeer: false))
        XCTAssertThrowsError(try fixture.evidence(includeCaller: false))
        let response = fixture.response()
        let unscoped = AccountDeviceListSnapshot(generatedAtEpochMilliseconds: response.generatedAtEpochMilliseconds,
            callerDeviceId: response.callerDeviceId, truncated: false, devices: response.devices)
        XCTAssertThrowsError(try AudioAccountMembership.verifyFreshResponse(unscoped,
            account: fixture.account, local: fixture.local, peer: fixture.peer,
            requestStartedMilliseconds: fixture.time, receivedMilliseconds: fixture.time,
            requestStartedMonotonic: fixture.monotonicStart, receivedMonotonic: fixture.monotonicStart))
    }

    func testSlowOldFutureAndOversizedLifetimeCannotExtendOfflineValidity() throws {
        let fixture = try AdmissionFixture()
        XCTAssertThrowsError(try fixture.evidence(received: fixture.time + 30_001))
        XCTAssertThrowsError(try fixture.evidence(generated: fixture.time - 30_001))
        XCTAssertThrowsError(try fixture.evidence(generated: .max))
        XCTAssertThrowsError(try fixture.evidence(received: fixture.time - 1))
        XCTAssertThrowsError(try fixture.evidence(elapsedMonotonicMilliseconds: 30_001))
        XCTAssertThrowsError(try fixture.evidence(elapsedMonotonicMilliseconds: -1))
        XCTAssertThrowsError(try fixture.evidence(lifetime: 1_000, elapsedMonotonicMilliseconds: 1_000))
        XCTAssertThrowsError(try fixture.evidence(lifetime: 3_600_001))
        XCTAssertThrowsError(try fixture.evidence(lifetime: 0))
        XCTAssertThrowsError(try fixture.evidence(received: fixture.time + 1_000, lifetime: 1_000))
        let receipt = try fixture.evidence(received: fixture.time + 20_000)
        XCTAssertEqual(receipt.expiresAtMilliseconds, fixture.time + 3_600_000)
        XCTAssertThrowsError(try receipt.validate(account: fixture.account, local: fixture.local,
            peer: fixture.peer, nowMilliseconds: receipt.expiresAtMilliseconds))
    }

    func testAuthorityAndStructuredAccountScopeCannotBeSubstituted() throws {
        let fixture = try AdmissionFixture()
        let evidence = try fixture.evidence()
        let anotherIssuer = try AudioAccountIdentity(authority: "https://other.example.invalid",
            tenantID: fixture.account.tenantID, userID: fixture.account.userID)
        XCTAssertThrowsError(try evidence.validate(account: anotherIssuer, local: fixture.local,
            peer: fixture.peer, nowMilliseconds: fixture.time))
        let first = try AudioAccountIdentity(authority: "issuer", tenantID: "a/b", userID: "c")
        let second = try AudioAccountIdentity(authority: "issuer", tenantID: "a", userID: "b/c")
        XCTAssertEqual(first.serverScope, second.serverScope)
        XCTAssertNotEqual(first, second)
        XCTAssertThrowsError(try AudioProtocolIdentity(deviceID: fixture.peer.deviceID,
            algorithm: .ed25519, fingerprint: String(repeating: "Ａ", count: 64)))
    }

    func testOfflineLeaseExpiresMonotonicallyAndNeverRevivesAfterAClockRollback() throws {
        let fixture = try AdmissionFixture()
        let clock = AdmissionClock(wall: fixture.time)
        let lease = try fixture.lease(clock: clock)
        XCTAssertTrue(lease.isCurrent)
        clock.advanceMonotonic(.seconds(3_600))
        XCTAssertEqual(lease.failure, .expired) // Wall clock deliberately stayed fixed.
        clock.advanceMonotonic(.seconds(-3_600))
        XCTAssertEqual(lease.failure, .expired)
        let other = try fixture.lease(clock: clock)
        clock.wall = fixture.time - 1
        XCTAssertEqual(other.failure, .clockMovedBackwards)
        clock.wall = fixture.time
        XCTAssertEqual(other.failure, .clockMovedBackwards)
    }

    func testAccountPeerAndExplicitRevocationArePermanentForTheLease() throws {
        let fixture = try AdmissionFixture()
        let clock = AdmissionClock(wall: fixture.time)
        let accountLease = try fixture.lease(clock: clock)
        clock.setAccount(false)
        XCTAssertEqual(accountLease.failure, .accountChanged)
        clock.setAccount(true)
        XCTAssertEqual(accountLease.failure, .accountChanged)
        let peerLease = try fixture.lease(clock: clock)
        clock.setPeer(false)
        XCTAssertEqual(peerLease.failure, .peerChanged)
        clock.setPeer(true)
        XCTAssertEqual(peerLease.failure, .peerChanged)
        let revoked = try fixture.lease(clock: clock)
        revoked.revoke()
        XCTAssertEqual(revoked.failure, .revoked)
    }

    func testCarrierEffectCheckDoesNotReenterPeerButKeepsLatchedFailures() throws {
        let fixture = try AdmissionFixture(), clock = AdmissionClock(wall: 1_000_000)
        let lease = try fixture.lease(clock: clock)
        clock.setPeer(false)
        try lease.requireEffectCurrent() // Carrier separately owns/validates this peer under its lock.
        XCTAssertEqual(lease.failure, .peerChanged)
        XCTAssertThrowsError(try lease.requireEffectCurrent()) {
            XCTAssertEqual($0 as? AudioMembershipLeaseFailure, .peerChanged)
        }
    }

    func testReconnectingCannotRestartTheSameOfflineEvidenceLifetime() throws {
        let fixture = try AdmissionFixture()
        let evidence = try fixture.evidence()
        let clock = AdmissionClock(wall: fixture.time)
        let first = try AudioMembershipLease(evidence: evidence, ownerID: UUID(),
            account: fixture.account, local: fixture.local, peer: fixture.peer,
            wallMilliseconds: { clock.wall }, monotonicNow: { clock.monotonic },
            isAccountCurrent: { true }, isPeerCurrent: { true })
        clock.advanceMonotonic(.seconds(3_601))
        XCTAssertEqual(first.failure, .expired)
        // The wall clock is unchanged. A replacement connection cannot give
        // the same old account response a new continuous-clock deadline.
        XCTAssertThrowsError(try AudioMembershipLease(evidence: evidence, ownerID: UUID(),
            account: fixture.account, local: fixture.local, peer: fixture.peer,
            wallMilliseconds: { clock.wall }, monotonicNow: { clock.monotonic },
            isAccountCurrent: { true }, isPeerCurrent: { true }))
    }

    func testPermissionBindsSourceEndpointStreamAndOwner() async throws {
        let fixture = try AdmissionFixture()
        let service = try AudioPlaybackApprovalService()
        let request = try fixture.request()
        let task = Task { try await service.requestApproval(request, isCurrent: { true }) }
        try await waitForPrompt(service)
        XCTAssertTrue(service.resolve(request, allowOnce: true))
        let permission = try await task.value
        XCTAssertTrue(permission.approves(ownerID: request.ownerID, streamID: request.streamID,
            source: request.source, outputEndpointUID: request.outputEndpointUID))
        XCTAssertFalse(permission.approves(ownerID: UUID(), streamID: request.streamID,
            source: request.source, outputEndpointUID: request.outputEndpointUID))
        XCTAssertFalse(permission.approves(ownerID: request.ownerID, streamID: UUID(),
            source: request.source, outputEndpointUID: request.outputEndpointUID))
        XCTAssertFalse(permission.approves(ownerID: request.ownerID, streamID: request.streamID,
            source: request.source, outputEndpointUID: "another-endpoint"))
        let file = AudioPlaybackSource.originalFile(transferID: UUID(), length: 1, sha256: Data(repeating: 0, count: 32))
        XCTAssertFalse(permission.approves(ownerID: request.ownerID, streamID: request.streamID,
            source: file, outputEndpointUID: request.outputEndpointUID))
        permission.revoke()
        XCTAssertFalse(permission.isApproved)
        XCTAssertNil(service.pendingRequest)
    }

    func testStaleTapBusyAndOwnerReplacementCannotApproveAnotherPrompt() async throws {
        let fixture = try AdmissionFixture()
        let service = try AudioPlaybackApprovalService()
        let first = try fixture.request(), second = try fixture.request()
        let firstTask = Task { try await service.requestApproval(first, isCurrent: { true }) }
        try await waitForPrompt(service)
        do { _ = try await service.requestApproval(second, isCurrent: { true }); XCTFail("accepted concurrent prompt") }
        catch { XCTAssertEqual(error as? AudioPlaybackApprovalError, .busy) }
        XCTAssertFalse(service.resolve(second, allowOnce: true))
        service.cancel(ownerID: first.ownerID)
        do { _ = try await firstTask.value; XCTFail("cancelled owner approved") }
        catch { XCTAssertEqual(error as? AudioPlaybackApprovalError, .ownerReplaced) }
        let secondTask = Task { try await service.requestApproval(second, isCurrent: { true }) }
        try await waitForPrompt(service)
        XCTAssertFalse(service.resolve(first, allowOnce: true))
        service.dismiss()
        do { _ = try await secondTask.value; XCTFail("dismissed prompt approved") }
        catch { XCTAssertEqual(error as? AudioPlaybackApprovalError, .rejected) }
    }

    func testOwnerIsRecheckedAtDecisionAndCancellationClearsThePrompt() async throws {
        let fixture = try AdmissionFixture()
        let service = try AudioPlaybackApprovalService()
        let request = try fixture.request()
        var current = true
        let task = Task { try await service.requestApproval(request, isCurrent: { current }) }
        try await waitForPrompt(service)
        current = false
        XCTAssertTrue(service.resolve(request, allowOnce: true))
        do { _ = try await task.value; XCTFail("stale owner approved") }
        catch { XCTAssertEqual(error as? AudioPlaybackApprovalError, .ownerReplaced) }
        let next = try fixture.request()
        let cancelled = Task { try await service.requestApproval(next, isCurrent: { true }) }
        try await waitForPrompt(service)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("cancelled task approved") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertNil(service.pendingRequest)
    }

    func testPromptDeadlineAndSourceDescriptorValidation() async throws {
        let fixture = try AdmissionFixture()
        let service = try AudioPlaybackApprovalService(decisionTimeout: .milliseconds(1))
        do { _ = try await service.requestApproval(fixture.request(), isCurrent: { true }); XCTFail("timeout approved") }
        catch { XCTAssertEqual(error as? AudioPlaybackApprovalError, .timedOut) }
        XCTAssertNil(service.pendingRequest)
        XCTAssertThrowsError(try AudioPlaybackApprovalService(decisionTimeout: .seconds(61)))
        XCTAssertThrowsError(try AudioPlaybackSource(offer: .init(streamID: UUID(), body: .accept(receiveWindowBytes: 6))))
        XCTAssertThrowsError(try AudioPlaybackSource(offer: .init(streamID: UUID(), body: .fileOffer(
            transferID: UUID(), length: 5, sha256: Data([0])))))
    }

    func testImmediatePublishedDecisionCannotLeaveAStalePrompt() async throws {
        let fixture = try AdmissionFixture()
        let service = try AudioPlaybackApprovalService()
        let subscription = service.$pendingRequest.sink { request in
            if let request { service.resolve(request, allowOnce: true) }
        }
        defer { subscription.cancel() }
        let permission = try await service.requestApproval(fixture.request(), isCurrent: { true })
        XCTAssertTrue(permission.isApproved)
        XCTAssertNil(service.pendingRequest)
    }

    private func waitForPrompt(_ service: AudioPlaybackApprovalService) async throws {
        for _ in 0..<100 {
            if service.pendingRequest != nil { return }
            await Task.yield()
        }
        XCTFail("prompt was not installed")
        throw AudioPlaybackApprovalError.invalidRequest
    }
}

private struct AdmissionFixture {
    let account: AudioAccountIdentity
    let local: AudioProtocolIdentity
    let peer: AudioProtocolIdentity
    let time: Int64 = 1_000_000
    let monotonicStart = ContinuousClock.now
    init() throws {
        account = try .init(authority: "https://auth.example.invalid", tenantID: "tenant", userID: "user")
        local = try .init(deviceID: "11111111-1111-1111-1111-111111111111", algorithm: .ed25519,
                          fingerprint: String(repeating: "a", count: 64))
        peer = try .init(deviceID: "22222222-2222-2222-2222-222222222222", algorithm: .ed25519,
                         fingerprint: String(repeating: "b", count: 64))
    }
    func row(_ identity: AudioProtocolIdentity, caller: Bool, status: String = "active",
             fingerprint: String? = nil, algorithm: String? = nil) -> AccountDeviceRecord {
        .init(deviceId: identity.deviceID, deviceName: nil, status: status,
            protocolSigningAlgorithm: algorithm ?? identity.algorithm.rawValue,
            protocolPublicKeyFingerprint: fingerprint ?? identity.fingerprint,
            platformRawValue: nil, deviceModel: nil, osVersion: nil, appVersion: nil,
            lanAddresses: [], publicAddress: nil, capabilities: [], registeredAtEpochMilliseconds: nil,
            lastSeenAtEpochMilliseconds: nil, presenceUpdatedAtEpochMilliseconds: nil, online: false, isCaller: caller)
    }
    func response() -> AccountDeviceListSnapshot {
        .init(generatedAtEpochMilliseconds: time, callerDeviceId: local.deviceID, truncated: false,
              devices: [row(local, caller: true), row(peer, caller: false)], accountScope: account.serverScope)
    }
    func evidence(localStatus: String = "active", peerStatus: String = "active",
                  peerFingerprint: String? = nil, peerAlgorithm: String? = nil,
                  scope: String? = nil, truncated: Bool = false, includePeer: Bool = true, includeCaller: Bool = true,
                  received: Int64? = nil, generated: Int64? = nil, lifetime: Int64 = 3_600_000,
                  elapsedMonotonicMilliseconds: Int64 = 0) throws -> AudioAccountMembership {
        var rows: [AccountDeviceRecord] = []
        if includeCaller { rows.append(row(local, caller: true, status: localStatus)) }
        if includePeer { rows.append(row(peer, caller: false, status: peerStatus, fingerprint: peerFingerprint, algorithm: peerAlgorithm)) }
        let response = AccountDeviceListSnapshot(generatedAtEpochMilliseconds: generated ?? time,
            callerDeviceId: local.deviceID, truncated: truncated, devices: rows, accountScope: scope ?? account.serverScope)
        return try .verifyFreshResponse(response, account: account, local: local, peer: peer,
            requestStartedMilliseconds: time, receivedMilliseconds: received ?? time,
            requestStartedMonotonic: monotonicStart,
            receivedMonotonic: monotonicStart.advanced(by: .milliseconds(elapsedMonotonicMilliseconds)),
            lifetimeMilliseconds: lifetime)
    }
    func request() throws -> AudioPlaybackApprovalRequest {
        try .init(ownerID: UUID(), offer: .init(streamID: UUID(), body: .captureOffer(.init(
            sampleRate: 44_100, channels: 2, encoding: .signed24, declaredValidBits: 24, waveChannelMask: 3))),
            membership: evidence(), outputEndpointUID: "selected-output")
    }
    func lease(clock: AdmissionClock) throws -> AudioMembershipLease {
        try .init(evidence: evidence(), ownerID: UUID(), account: account, local: local, peer: peer,
            wallMilliseconds: { clock.wall }, monotonicNow: { clock.monotonic },
            isAccountCurrent: { clock.accountCurrent }, isPeerCurrent: { clock.peerCurrent })
    }
}

private final class AdmissionClock: Sendable {
    private struct State: Sendable {
        var wall: Int64
        var monotonic: ContinuousClock.Instant = .now
        var account = true
        var peer = true
    }
    private let state: OSAllocatedUnfairLock<State>
    init(wall: Int64) { state = .init(initialState: State(wall: wall)) }
    var wall: Int64 { get { state.withLock { $0.wall } } set { state.withLock { $0.wall = newValue } } }
    var monotonic: ContinuousClock.Instant { state.withLock { $0.monotonic } }
    var accountCurrent: Bool { state.withLock { $0.account } }
    var peerCurrent: Bool { state.withLock { $0.peer } }
    func advanceMonotonic(_ duration: Duration) { state.withLock { $0.monotonic = $0.monotonic.advanced(by: duration) } }
    func setAccount(_ value: Bool) { state.withLock { $0.account = value } }
    func setPeer(_ value: Bool) { state.withLock { $0.peer = value } }
}
