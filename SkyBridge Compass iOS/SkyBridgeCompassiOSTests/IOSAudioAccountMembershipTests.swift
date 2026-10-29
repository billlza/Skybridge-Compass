import XCTest
import Foundation
import Network
import Security
import os
import SkyBridgeProtocolCore
@testable import SkyBridgeCompass_iOS

/// Controlled, already-authenticated registry responses and Finished identities.
/// These execute the native carrier, account adapter and presence engine; they
/// do not stand in for real pairing, production HTTP or physical audio playback.
@MainActor
final class IOSAudioAccountMembershipTests: XCTestCase {
    func testRenewalContinuesOnlyTheExactLeaseWithFreshAccountEvidence() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        f.backend.lists.append { _ in f.response() }
        let channel = try f.channel(), lease = try await f.provider.lease(for: channel)
        let before = lease.evidence
        f.clock.advance(1_000)
        f.backend.lists.append { _ in f.response() }
        let continued = try await f.provider.renew(for: channel, continuing: lease)
        XCTAssertTrue(continued === lease)
        XCTAssertNotEqual(lease.evidence.id, before.id)
        XCTAssertGreaterThan(lease.evidence.expiresAtMilliseconds, before.expiresAtMilliseconds)
        XCTAssertEqual(lease.ownerID, channel.ownerID)
        XCTAssertEqual(f.backend.listCalls, 2)
        do {
            _ = try await f.provider.renew(for: f.channel(), continuing: lease)
            XCTFail("A different channel borrowed the continuation")
        } catch { XCTAssertEqual(f.backend.listCalls, 2) }
    }

    func testExpiredLocalBearerCannotQueryOrRevokeAnExistingFiniteLease() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        f.backend.lists.append { _ in f.response() }
        let channel = try f.channel(), lease = try await f.provider.lease(for: channel)
        let before = lease.evidence
        f.tokenExpiration = Date().timeIntervalSince1970 - 10
        do {
            _ = try await f.provider.renew(for: channel, continuing: lease)
            XCTFail("Expired bearer renewed membership")
        } catch let unavailable as AudioMembershipRequestUnavailable {
            guard case SignalServerClientCompat.ClientError.expiredAuthentication = unavailable.underlying else {
                return XCTFail("Local expiry lost its cause: \(unavailable.underlying)")
            }
        }
        XCTAssertEqual(lease.evidence, before); XCTAssertTrue(lease.isCurrent)
        XCTAssertEqual(f.clientsBuilt, 1); XCTAssertEqual(f.backend.listCalls, 1)
    }

    func testRefreshTransportClassificationKeepsOnlyTheOriginalGrant() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        f.backend.lists.append { _ in f.response() }
        let channel = try f.channel(), lease = try await f.provider.lease(for: channel)
        let before = lease.evidence
        let temporary: [any Error] = [SupabaseService.SupabaseError.network(URLError(.notConnectedToInternet)),
            SupabaseService.SupabaseError.httpStatus(code: 503, message: nil)]
        for failure in temporary {
            f.resolveFailure = failure
            do { _ = try await f.provider.renew(for: channel, continuing: lease); XCTFail("Failure hidden") }
            catch { XCTAssertTrue(error is AudioMembershipRequestUnavailable) }
            XCTAssertEqual(lease.evidence, before); XCTAssertTrue(lease.isCurrent)
        }
        let terminal: [any Error] = [SupabaseService.SupabaseError.network(URLError(.secureConnectionFailed)),
            SupabaseService.SupabaseError.httpStatus(code: 403, message: nil),
            SupabaseService.SupabaseError.httpStatus(code: 503, message: #"{"error":"device_revoked"}"#),
            SignalServerClientCompat.ClientError.missingAuthentication,
            SignalServerClientCompat.ClientError.invalidAuthenticationClaims]
        for failure in terminal {
            f.resolveFailure = failure
            do { _ = try await f.provider.renew(for: channel, continuing: lease); XCTFail("Failure hidden") }
            catch { XCTAssertFalse(error is AudioMembershipRequestUnavailable) }
        }
        XCTAssertEqual(f.backend.listCalls, 1)
    }

    func testLeaseUsesExactFinishedBindingAndOfflineReconnectKeepsOriginalExpiry() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        f.backend.lists.append { binding in
            XCTAssertEqual(binding.deviceId, f.binding.deviceId)
            XCTAssertEqual(binding.protocolPublicKeyBytes, f.binding.protocolPublicKeyBytes)
            XCTAssertEqual(binding.protocolPublicKeyFingerprint, f.binding.protocolPublicKeyFingerprint)
            return f.response()
        }
        let channel = try f.channel()
        let first = try await f.provider.lease(for: channel)
        XCTAssertEqual(first.ownerID, channel.ownerID)
        XCTAssertEqual(first.evidence.localIdentity, try AudioProtocolIdentity(f.binding))
        channel.close(); XCTAssertFalse(first.isCurrent)
        f.clock.advance(500_000)
        // Offline reuse must never ask the resolver to renew an expired JWT.
        f.resolveFailure = URLError(.notConnectedToInternet)
        let reconnected = try await f.provider.lease(for: f.channel())
        XCTAssertEqual(first.evidence.id, reconnected.evidence.id)
        XCTAssertEqual(first.evidence.expiresAtMonotonic, reconnected.evidence.expiresAtMonotonic)
        XCTAssertEqual(f.resolutions, 1); XCTAssertEqual(f.backend.listCalls, 1)
        XCTAssertTrue(reconnected.isCurrent)
        f.clock.advance(3_100_000)
        XCTAssertFalse(reconnected.isCurrent)
        do { _ = try await f.provider.lease(for: f.channel()); XCTFail("Expired offline evidence reused") }
        catch let error as URLError { XCTAssertEqual(error.code, .notConnectedToInternet) }
    }

    func testThreadSafeOwnerPredicateCannotFollowAReplacementChannel() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let channel = try f.channel(), predicate = channel.isCurrentForMembership
        let initiallyCurrent = await Task.detached { predicate() }.value
        XCTAssertTrue(initiallyCurrent)
        channel.close()
        let closedCurrent = await Task.detached { predicate() }.value
        XCTAssertFalse(closedCurrent)
        let replacement = try f.channel()
        XCTAssertTrue(replacement.isCurrentForMembership())
        XCTAssertFalse(predicate())
        let replacementPredicate = replacement.isCurrentForMembership
        f.close()
        let invalidatedCurrent = await Task.detached { replacementPredicate() }.value
        XCTAssertFalse(invalidatedCurrent)
    }

    func testSameAccountReloginDuringCredentialResolutionRejectsOldFactoryRequest() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let gate = RegistryGate<Void>(), captured = f.context
        defer { gate.finish(.failure(CancellationError())) }
        f.resolveGate = gate
        let request = Task { try await f.factory.makeClient(expected: captured) }
        try await gate.waitForArrival()
        f.relogin()
        gate.finish(.success(()))
        do { _ = try await request.value; XCTFail("New login lent credentials to old request") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
        XCTAssertEqual(f.clientsBuilt, 0)
    }

    func testAuthorityChangeDuringCredentialResolutionBuildsNoClient() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let gate = RegistryGate<Void>(); f.resolveGate = gate
        defer { gate.finish(.failure(CancellationError())) }
        let request = Task { try await f.factory.makeClient(expected: f.context) }
        try await gate.waitForArrival()
        f.authority = "https://replacement.example.invalid"
        gate.finish(.success(()))
        do { _ = try await request.value; XCTFail("Authority changed across refresh") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
        XCTAssertEqual(f.clientsBuilt, 0)
    }

    func testAbsentAudioEpochAllowsOrdinaryRegistryButNeverGrantsAudio() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        f.context?.authorization.revoke(); f.context = nil
        f.backend.lists.append { _ in f.response() }
        _ = try await f.provider.listAccountDevices(binding: f.nativeBinding, context: nil)
        XCTAssertEqual(f.backend.listCalls, 1)
        do { _ = try await f.provider.lease(for: f.channel()); XCTFail("Missing epoch granted audio") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
        XCTAssertEqual(f.backend.listCalls, 1)
    }

    func testNilContextCannotBorrowEpochPublishedWhileCredentialsResolve() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        f.context?.authorization.revoke(); f.context = nil
        let gate = RegistryGate<Void>(); f.resolveGate = gate
        defer { gate.finish(.failure(CancellationError())) }
        let request = Task { try await f.factory.makeClient(expected: nil) }
        try await gate.waitForArrival()
        f.relogin()
        gate.finish(.success(()))
        do { _ = try await request.value; XCTFail("Nil request borrowed published epoch") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
        XCTAssertEqual(f.clientsBuilt, 0)
    }

    func testHeartbeat200InactiveRevokesLeaseAndPreventsLatePositiveRefresh() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        f.backend.lists.append { _ in f.response() }
        let channel = try f.channel(), lease = try await f.provider.lease(for: channel)
        let gate = RegistryGate<AccountDeviceListSnapshot>()
        defer { gate.finish(.failure(CancellationError())) }
        f.backend.lists.append { _ in try await gate.wait() }
        let refresh = Task { try await f.provider.lease(for: f.channel(), refresh: true) }
        try await gate.waitForArrival()
        f.backend.heartbeats.append { try RegistryFixture.heartbeat(persisted: false, reason: "device_not_active") }
        try await f.provider.registerPresence(binding: f.nativeBinding, report: f.report(), context: f.context)
        XCTAssertFalse(lease.isCurrent)
        gate.finish(.success(f.response()))
        do { _ = try await refresh.value; XCTFail("Late positive GET revived heartbeat contradiction") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
        do {
            try await channel.send(.init(streamID: UUID(), body: .fileOffer(
                transferID: UUID(), length: 8, sha256: Data(repeating: 0x12, count: 32))),
                requireEffectAuthorization: { try lease.requireEffectCurrent() })
            XCTFail("Revoked effect reached native enqueue")
        } catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
        XCTAssertEqual(f.frames, 0)
    }

    func testHeartbeatTransportAndRegistryFailuresDoNotInventRevocation() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        f.backend.lists.append { _ in f.response() }
        let lease = try await f.provider.lease(for: f.channel())
        for reason in ["written", "throttled", "registry_unavailable", "registry_not_configured"] {
            f.backend.heartbeats.append { try RegistryFixture.heartbeat(persisted: false, reason: reason) }
            try await f.provider.registerPresence(binding: f.nativeBinding, report: f.report(), context: f.context)
            XCTAssertTrue(lease.isCurrent, reason)
        }
        let failures: [Error] = [URLError(.notConnectedToInternet), CancellationError(),
            SignalServerClientCompat.ClientError.serverRejected(429, "{}"),
            SignalServerClientCompat.ClientError.malformedResponse("fixture")]
        for failure in failures {
            f.backend.heartbeats.append { throw failure }
            do { try await f.provider.registerPresence(binding: f.nativeBinding, report: f.report(), context: f.context); XCTFail("Failure hidden") }
            catch { XCTAssertTrue(lease.isCurrent) }
        }
    }

    func testCancelledHeartbeatKnownInactiveStillRevokesExactCaller() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        f.backend.lists.append { _ in f.response() }
        let lease = try await f.provider.lease(for: f.channel())
        let gate = RegistryGate<SignalServerClient.PresenceRegisterResponseBody>()
        defer { gate.finish(.failure(CancellationError())) }
        f.backend.heartbeats.append { try await gate.wait() }
        let request = Task { try await f.provider.registerPresence(binding: f.nativeBinding, report: f.report(), context: f.context) }
        try await gate.waitForArrival(); request.cancel()
        gate.finish(.failure(SignalServerClientCompat.ClientError.serverRejected(403, #"{"error":"device_revoked"}"#)))
        do { try await request.value; XCTFail("Inactive rejection hidden") }
        catch { XCTAssertEqual(SignalServerClientCompat.presenceFailure(for: error), .deviceNotActive(code: "device_revoked")) }
        XCTAssertFalse(lease.isCurrent)
    }

    func testSuspendedPresenceAppliesCompletedNegativeGETBeforeDiscardingUI() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let presenceGate = RegistryGate<AccountDeviceListSnapshot>(), audioGate = RegistryGate<AccountDeviceListSnapshot>()
        defer { presenceGate.finish(.failure(CancellationError())); audioGate.finish(.failure(CancellationError())) }
        f.backend.heartbeats.append { try RegistryFixture.heartbeat(persisted: true, reason: "written") }
        f.backend.lists.append { _ in try await presenceGate.wait() }
        let service = f.presenceService(); defer { service.updateAuthentication(principal: nil) }
        service.updateAuthentication(principal: .init(userID: "audio-user", tenantID: "audio-tenant"))
        try await presenceGate.waitForArrival()
        let waitingForRefresh = Task { await service.waitForCurrentRefresh() }
        f.backend.lists.append { _ in try await audioGate.wait() }
        let pendingAudio = Task { try await f.provider.lease(for: f.channel()) }
        try await audioGate.waitForArrival()
        service.handleScenePhase(isActive: false)
        presenceGate.finish(.success(f.response(includePeer: false)))
        await waitingForRefresh.value
        audioGate.finish(.success(f.response()))
        do { _ = try await pendingAudio.value; XCTFail("Cancelled UI dropped valid negative registry fact") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
        XCTAssertNil(service.accountDevices)
    }

    func testConfirmedRemovalAfterSuspendRevokesAndCannotBeUndoneByLateGET() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        f.backend.heartbeats.append { try RegistryFixture.heartbeat(persisted: true, reason: "written") }
        f.backend.lists.append { _ in f.response() }
        let service = f.presenceService(); defer { service.updateAuthentication(principal: nil) }
        service.updateAuthentication(principal: .init(userID: "audio-user", tenantID: "audio-tenant"))
        await service.waitForCurrentRefresh()
        f.backend.lists.append { _ in f.response() }
        let lease = try await f.provider.lease(for: f.channel())
        let audioGate = RegistryGate<AccountDeviceListSnapshot>(), removalGate = RegistryGate<Void>()
        defer { audioGate.finish(.failure(CancellationError())); removalGate.finish(.failure(CancellationError())) }
        f.backend.lists.append { _ in try await audioGate.wait() }
        let pendingAudio = Task { try await f.provider.lease(for: f.channel(), refresh: true) }
        try await audioGate.waitForArrival()
        f.backend.removals.append { _, scope in
            XCTAssertEqual(scope, "audio-tenant/audio-user")
            try await removalGate.wait()
        }
        let target = f.row(f.peer, caller: false), scope = service.removalScope
        let removal = Task { await service.removeDevice(target, expectedScope: scope) }
        try await removalGate.waitForArrival()
        service.handleScenePhase(isActive: false)
        removalGate.finish(.success(())); await removal.value
        XCTAssertFalse(lease.isCurrent)
        audioGate.finish(.success(f.response()))
        do { _ = try await pendingAudio.value; XCTFail("Late GET restored removed device") }
        catch { XCTAssertEqual(error as? AudioAccountProviderError, .contradicted) }
        XCTAssertTrue(service.accountDevices?.devices.contains(where: { $0.deviceId == target.deviceId }) == true,
                      "Suspended UI must not claim it applied the old generation")
    }

    func testOldEpochNegativeHeartbeatCannotRevokeNewSameAccountLease() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let gate = RegistryGate<SignalServerClient.PresenceRegisterResponseBody>()
        defer { gate.finish(.failure(CancellationError())) }
        f.backend.heartbeats.append { try await gate.wait() }
        let captured = f.context
        let old = Task { try await f.provider.registerPresence(binding: f.nativeBinding, report: f.report(), context: captured) }
        try await gate.waitForArrival(); f.relogin()
        f.backend.lists.append { _ in f.response() }
        let current = try await f.provider.lease(for: f.channel())
        gate.finish(.success(try RegistryFixture.heartbeat(persisted: false, reason: "device_not_active")))
        do { try await old.value; XCTFail("Old response accepted under new epoch") }
        catch { XCTAssertFalse(captured?.authorization.isCurrent ?? true) }
        XCTAssertTrue(current.isCurrent)
    }

    func testAccountEpochIsCapturedBeforeAsynchronousPresenceIdentityLookup() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let bindingGate = RegistryGate<ProtocolIdentityBindingCompat>()
        defer { bindingGate.finish(.failure(CancellationError())) }
        let attempts = RegistryCounter()
        let service = f.presenceService(loadBinding: {
            guard attempts.increment() == 1 else { throw RegistryTestError.unexpectedRequest }
            return try await bindingGate.wait()
        })
        defer { service.updateAuthentication(principal: nil) }
        service.updateAuthentication(principal: .init(userID: "audio-user", tenantID: "audio-tenant"))
        try await bindingGate.waitForArrival()
        f.relogin()
        // Leave the task uncancelled: cancellation alone must not make this
        // assertion pass. The following list lookup is independently rejected
        // by its identity loader, so only this heartbeat can build a client.
        bindingGate.finish(.success(f.nativeBinding))
        await service.waitForCurrentRefresh()
        XCTAssertEqual(f.clientsBuilt, 0); XCTAssertEqual(f.backend.heartbeatCalls, 0)
    }
}

@MainActor
private final class RegistryFixture {
    let binding: ProtocolIdentityBinding
    let nativeBinding: ProtocolIdentityBindingCompat
    let local: AudioProtocolIdentity
    let peer: AudioProtocolIdentity
    let account: AudioAccountIdentity
    let backend = RegistryBackend()
    let clock = RegistryClock()
    var authority = "https://audio-registry.example.invalid"
    var context: AudioAccountContext?
    var intent = IOSAuthenticationIntent()
    var resolveGate: RegistryGate<Void>?
    var resolveFailure: Error?
    var tokenExpiration: TimeInterval = 4_102_444_800
    var resolutions = 0, clientsBuilt = 0, frames = 0
    private var sessions: [IOSAudioSession] = []
    private var channels: [IOSAudioChannel] = []
    lazy var factory = IOSAudioAccountClientFactory(currentContext: { self.context },
        configuredAuthority: { self.authority }, resolveSession: {
            self.resolutions += 1
            let intent = self.intent, session = try self.authSession()
            if let gate = self.resolveGate { try await gate.wait() }
            if let failure = self.resolveFailure { throw failure }
            return .init(session: session, requireCurrent: { try intent.requireCurrent() })
        }, buildClient: { frozen in
            self.clientsBuilt += 1
            return RegistryClient(frozen: frozen, backend: self.backend)
        })
    lazy var provider = IOSAudioAccountMembershipProvider(factory: factory,
        wall: { [clock] in clock.wall }, monotonic: { [clock] in clock.monotonic })

    init() throws {
        binding = try ProtocolIdentityBinding(deviceId: "audio-membership-ios-local", protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: Data(repeating: 0x47, count: 32))
        local = try AudioProtocolIdentity(binding)
        nativeBinding = try ProtocolIdentityBindingCompat(deviceId: binding.deviceId, protocolSigningAlgorithm: .ed25519,
            protocolPublicKeyBytes: binding.protocolPublicKeyBytes, protocolPublicKeyFingerprint: binding.protocolPublicKeyFingerprint)
        peer = try AudioProtocolIdentity(deviceID: "audio-membership-mac-peer", algorithm: .ed25519,
                                        fingerprint: String(repeating: "b", count: 64))
        account = try AudioAccountIdentity(authority: "https://audio-registry.example.invalid", tenantID: "audio-tenant", userID: "audio-user")
        context = AudioAccountContext(authorization: AccountAudioAuthorization(), account: account)
    }
    func relogin() {
        context?.authorization.revoke(); intent.invalidate(); intent = IOSAuthenticationIntent()
        context = AudioAccountContext(authorization: AccountAudioAuthorization(), account: account)
    }
    func channel() throws -> IOSAudioChannel {
        let generation = UUID()
        let keys = SkyBridgeCompass_iOS.SessionKeys(sendKey: Data(repeating: 0x21, count: 32),
            receiveKey: Data(repeating: 0x43, count: 32), negotiatedSuite: .qperiaptABI2PolicyBound,
            role: .initiator, transcriptHash: Data(repeating: 0x65, count: 32))
        let snapshot = IOSAudioPeerSnapshot(generation: generation, sessionID: keys.sessionId, identity: peer,
            capabilities: [AudioStreamingWire.fileReceiveCapability], filePort: 8080,
            acceptedMaterialDigest: Data(repeating: 0x23, count: 32))
        let session = try IOSAudioSession(generation: generation, keys: keys, localIdentity: binding, peer: snapshot,
            fileRoute: .network(.hostPort(host: "127.0.0.1", port: 8080)), requireConnection: {}, sendFrame: { [weak self] _, completion in
                self?.frames += 1; completion.completeWrite(.success(()))
            }, cancelTransport: {})
        sessions.append(session)
        let channel = try session.open(requiringFingerprint: peer.fingerprint)
        channels.append(channel)
        return channel
    }
    func close() {
        channels.forEach { $0.close() }; channels.removeAll()
        sessions.forEach { $0.invalidate() }; sessions.removeAll()
    }
    func response(includePeer: Bool = true) -> AccountDeviceListSnapshot {
        var rows = [row(local, caller: true)]
        if includePeer { rows.append(row(peer, caller: false)) }
        return .init(generatedAtEpochMilliseconds: clock.wall, callerDeviceId: binding.deviceId,
                     truncated: false, devices: rows, accountScope: account.serverScope)
    }
    func row(_ identity: AudioProtocolIdentity, caller: Bool) -> AccountDeviceRecord {
        .init(deviceId: identity.deviceID, deviceName: nil, status: "active",
              protocolSigningAlgorithm: identity.algorithm.rawValue, protocolPublicKeyFingerprint: identity.fingerprint,
              platformRawValue: nil, deviceModel: nil, osVersion: nil, appVersion: nil, lanAddresses: [], publicAddress: nil,
              capabilities: [], registeredAtEpochMilliseconds: nil, lastSeenAtEpochMilliseconds: nil,
              presenceUpdatedAtEpochMilliseconds: nil, online: false, isCaller: caller)
    }
    func report() throws -> AccountDevicePresenceReport {
        try .init(deviceName: "Fixture", platform: .iOS, deviceModel: "Fixture", osVersion: "test", lanAddresses: [], capabilities: [.fileTransfer])
    }
    func presenceService(loadBinding: AccountPresenceService.BindingLoader? = nil) -> AccountPresenceService {
        let binding = nativeBinding
        let loader: AccountPresenceService.BindingLoader
        if let loadBinding { loader = loadBinding } else { loader = { binding } }
        return AccountPresenceService(signalServer: SignalServerClientCompat(), loadBinding: loader,
            reportProvider: { try self.report() }, audioRegistry: provider, refreshInterval: 3_600)
    }
    static func heartbeat(persisted: Bool, reason: String) throws -> SignalServerClient.PresenceRegisterResponseBody {
        try JSONDecoder().decode(SignalServerClient.PresenceRegisterResponseBody.self,
            from: JSONSerialization.data(withJSONObject: ["online": true, "persisted": persisted, "persistReason": reason]))
    }
    func authSession() throws -> AuthSession {
        func segment(_ object: [String: Any]) throws -> String {
            try JSONSerialization.data(withJSONObject: object).base64EncodedString().replacingOccurrences(of: "=", with: "")
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        }
        let token = try segment(["alg": "HS256"]) + "." + segment([
            "sub": "audio-user", "exp": tokenExpiration, "app_metadata": ["tenant_id": "audio-tenant"]]) + ".AQID"
        return AuthSession(accessToken: token, refreshToken: nil, userIdentifier: "audio-user", displayName: "Fixture", issuedAt: Date())
    }
}

/// Real Data Protection Keychain and production boot reader. Registry replies
/// and the passage of time remain controlled fixtures; no account HTTP or audio.
@MainActor
final class IOSNativeAudioMembershipPersistenceTests: XCTestCase {
    func testNativeCheckpointRestoresOriginalGrantAfterOwnerRecreationWithoutGET() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let owner = try NativeMembershipOwner(test: self)
        try await owner.install(in: f)
        f.backend.lists.append { _ in f.response() }
        let first = try await owner.provider(f).lease(for: f.channel())
        let checkpoint = try XCTUnwrap(owner.root.load()?.audioCheckpoint)
        let requests = f.backend.listCalls, resolutions = f.resolutions
        f.clock.advance(250_000)
        try await owner.recreate(in: f)
        f.resolveFailure = URLError(.notConnectedToInternet)
        let restored = try await owner.provider(f).lease(for: f.channel())
        XCTAssertEqual(restored.evidence, first.evidence)
        XCTAssertNotEqual(restored.ownerID, first.ownerID)
        XCTAssertEqual(try owner.root.load()?.audioCheckpoint, checkpoint)
        XCTAssertEqual(f.backend.listCalls, requests)
        XCTAssertEqual(f.resolutions, resolutions)
        XCTAssertTrue(restored.isCurrent)
    }

    func testDifferentBootRetiresNativeCheckpointWithoutRenewingOffline() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let owner = try NativeMembershipOwner(test: self)
        try await owner.install(in: f)
        f.backend.lists.append { _ in f.response() }
        _ = try await owner.provider(f).lease(for: f.channel())
        try await owner.recreate(in: f)
        f.resolveFailure = URLError(.notConnectedToInternet)
        let differentBoot = UUID()
        let provider = owner.provider(f, boot: { differentBoot })
        do { _ = try await provider.lease(for: f.channel()); XCTFail("Different boot restored old authority") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertNil(try owner.root.load()?.audioCheckpoint)
        XCTAssertTrue(try XCTUnwrap(owner.root.load()).observations.isEmpty)
    }

    func testInterruptedDeviceRequestRetiresEvidenceBeforeARecoveryGET() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let owner = try NativeMembershipOwner(test: self)
        try await owner.install(in: f)
        f.backend.lists.append { _ in f.response() }
        _ = try await owner.provider(f).lease(for: f.channel())
        let authorization = try XCTUnwrap(owner.state.audioAuthorization)
        let interrupted = try await owner.state.beginAudioMembershipObservation(for: authorization,
            keychain: owner.keychain)
        await interrupted.abandon()
        try await owner.recreate(in: f)
        XCTAssertNotNil(f.context, "Account context must remain available for a new device query")
        f.resolveFailure = URLError(.notConnectedToInternet)
        do { _ = try await owner.provider(f).lease(for: f.channel()); XCTFail("Interrupted request restored evidence") }
        catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
        XCTAssertNil(try owner.root.load()?.audioCheckpoint)
        XCTAssertTrue(try XCTUnwrap(owner.root.load()).observations.isEmpty)
    }

    func testRevokedNativeAuthorizationCannotRestoreAfterOwnerRecreation() async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let owner = try NativeMembershipOwner(test: self)
        try await owner.install(in: f)
        f.backend.lists.append { _ in f.response() }
        let first = try await owner.provider(f).lease(for: f.channel())
        try await owner.state.revokeAudio(expected: owner.state.witness())
        XCTAssertFalse(first.isCurrent)
        try await owner.recreate(in: f)
        XCTAssertNil(f.context)
        do { _ = try await owner.provider(f).lease(for: f.channel()); XCTFail("Revoked account restored a grant") }
        catch { XCTAssertEqual(error as? AudioMembershipLeaseFailure, .accountChanged) }
        XCTAssertNil(try owner.root.load()?.audioCheckpoint)
    }
}

@MainActor
final class IOSNativeAudioMembershipRecoveryQualificationTests: XCTestCase {
    private static let processToken = UUID().uuidString
    private struct Receipt: Codable {
        let identifier: UUID
        let phase: String
        let pid: Int32
        let processToken: String
        let boot: UUID
        let ticks: UInt64
        let loginID: UUID
        let checkpoint: Data
        let evidenceID: UUID
        let expiresAt: Int64
    }
    private enum Failure: Error { case invalidPhase, invalidPredecessor, sameProcess }

    /// Ordinary regression is isolated and self-cleaning. The explicit device
    /// lane launches a separate test-host process for each named phase.
    func testNativeAudioMembershipRecoveryFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let phase = environment["SKYBRIDGE_NATIVE_MEMBERSHIP_PHASE"] ?? "roundtrip"
        let identifier = try XCTUnwrap(UUID(uuidString:
            environment["SKYBRIDGE_NATIVE_MEMBERSHIP_ID"] ?? UUID().uuidString))
        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("NativeMembershipQualification", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(identifier.uuidString + ".json")
        if phase == "roundtrip" {
            addTeardownBlock { @MainActor in
                try NativeMembershipOwner(identifier: identifier).cleanup()
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
            for step in ["prepare", "restore", "reject", "cleanup"] {
                try await run(step, identifier: identifier, url: url, separateProcess: false)
            }
        } else {
            guard ["prepare", "restore", "reject", "cleanup"].contains(phase),
                  environment["SKYBRIDGE_NATIVE_MEMBERSHIP_ID"] != nil else { throw Failure.invalidPhase }
            try await run(phase, identifier: identifier, url: url, separateProcess: true)
        }
    }

    private func run(_ phase: String, identifier: UUID, url: URL, separateProcess: Bool) async throws {
        let f = try RegistryFixture(); defer { f.close() }
        let owner = try NativeMembershipOwner(identifier: identifier)
        let boot = try await IOSAudioBootWitness.read()
        let previous: Receipt?
        if phase == "prepare" {
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNil(try owner.root.load())
            try await owner.install(in: f)
            previous = nil
        } else {
            let saved = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
            guard saved.identifier == identifier,
                  saved.phase == ["restore": "prepare", "reject": "restore", "cleanup": "reject"][phase] else {
                throw Failure.invalidPredecessor
            }
            if separateProcess {
                guard saved.pid != getpid(), saved.processToken != Self.processToken else { throw Failure.sameProcess }
            }
            XCTAssertEqual(boot, saved.boot)
            XCTAssertGreaterThan(mach_continuous_time(), saved.ticks)
            try await owner.recreate(in: f)
            XCTAssertEqual(try owner.root.load()?.loginID, saved.loginID)
            previous = saved
        }
        let evidenceID: UUID
        let expiry: Int64
        let checkpoint: Data
        if phase == "prepare" || phase == "restore" {
            if phase == "prepare" { f.backend.lists.append { _ in f.response() } }
            else { f.resolveFailure = URLError(.notConnectedToInternet) }
            let lease = try await owner.provider(f).lease(for: f.channel())
            evidenceID = lease.evidence.id
            expiry = lease.evidence.expiresAtMilliseconds
            checkpoint = try XCTUnwrap(owner.root.load()?.audioCheckpoint)
            if let previous {
                XCTAssertEqual(evidenceID, previous.evidenceID)
                XCTAssertEqual(expiry, previous.expiresAt)
                XCTAssertEqual(checkpoint, previous.checkpoint)
                XCTAssertEqual(f.resolutions, 0)
                XCTAssertEqual(f.backend.listCalls, 0)
                let authorization = try XCTUnwrap(owner.state.audioAuthorization)
                let request = try await owner.state.beginAudioMembershipObservation(for: authorization,
                    keychain: owner.keychain)
                await request.abandon()
                XCTAssertEqual(try owner.root.load()?.observations.count, 1)
            }
            XCTAssertTrue(lease.isCurrent)
        } else {
            let previous = try XCTUnwrap(previous)
            evidenceID = previous.evidenceID; expiry = previous.expiresAt; checkpoint = previous.checkpoint
            if phase == "reject" {
                XCTAssertNotNil(f.context)
                f.resolveFailure = URLError(.notConnectedToInternet)
                do { _ = try await owner.provider(f).lease(for: f.channel()); XCTFail("Unsettled request restored authority") }
                catch { XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet) }
                XCTAssertEqual(f.resolutions, 1)
                XCTAssertEqual(f.backend.listCalls, 0)
            }
            XCTAssertNil(try owner.root.load()?.audioCheckpoint)
            XCTAssertTrue(try XCTUnwrap(owner.root.load()).observations.isEmpty)
        }
        let receipt = Receipt(identifier: identifier, phase: phase, pid: getpid(),
            processToken: Self.processToken, boot: boot, ticks: mach_continuous_time(),
            loginID: try XCTUnwrap(owner.root.load()?.loginID), checkpoint: checkpoint,
            evidenceID: evidenceID, expiresAt: expiry)
        if phase == "cleanup" {
            try owner.cleanup()
            try FileManager.default.removeItem(at: url)
            XCTAssertNil(try owner.root.load())
        } else {
            try JSONEncoder().encode(receipt).write(to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let attachment = XCTAttachment(data: try JSONEncoder().encode(receipt), uniformTypeIdentifier: "public.json")
        attachment.name = "native-membership-\(phase)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class IOSAudioBootWitnessTests: XCTestCase {
    func testProductionReaderKeepsTheSameIdentifierAcrossIndependentReads() async throws {
        let first = try await IOSAudioBootWitness.read()
        let second = try await IOSAudioBootWitness.read()
        XCTAssertEqual(first, second)
    }

    func testCancelledReadDoesNotReturnAnIdentifier() async throws {
        let task = Task { @MainActor in try await IOSAudioBootWitness.read() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled read returned a witness") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testInvalidNativeNamespaceFailsBeforeCreatingALockFile() throws {
        let lock = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try IOSAudioBootWitness.readNative(
            name: "group.com.skybridge.compass/long", lock: lock)) {
            guard case IOSAudioBootWitness.Failure.native(let step, _, _) = $0 else {
                return XCTFail("Unexpected failure: \($0)")
            }
            XCTAssertEqual(step, 1)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path))
    }
}

@MainActor
private final class NativeMembershipOwner {
    private let storage: DataProtectionAccountSessionStorage
    private let accessGroup: String
    private let service: String
    private(set) var keychain: KeychainManager
    private(set) var state: IOSAuthenticationSessionState
    var root: ProtectedAccountSessionStore<AuthSession> { .init(storage: storage) }

    init(test: XCTestCase? = nil, identifier: UUID = UUID()) throws {
        let group = try KeychainManager.requiredAccountAccessGroup(
            Bundle.main.object(forInfoDictionaryKey: "SkyBridgeAccountKeychainAccessGroup") as? String,
            bundleIdentifier: Bundle.main.bundleIdentifier)
        let service = "com.skybridge.native-membership-tests." + identifier.uuidString
        self.accessGroup = group; self.service = service
        storage = try .init(service: service, account: "fixture", accessGroup: group)
        keychain = KeychainManager(accountStorage: storage, loadLegacy: { nil }, deleteLegacy: {})
        state = IOSAuthenticationSessionState(storage: .live(keychain: keychain))
        test?.addTeardownBlock { @MainActor [self] in try cleanup() }
    }

    func cleanup() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "fixture",
            kSecAttrAccessGroup as String: accessGroup, kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedError(status)
        }
    }

    func install(in fixture: RegistryFixture) async throws {
        try await state.install(fixture.authSession(), intent: state.beginMutation())
        bind(fixture)
    }

    /// New native owner and session state over the same actual protected bytes.
    /// This controlled recreation is not a claim of an OS process restart.
    func recreate(in fixture: RegistryFixture) async throws {
        state.audioAuthorization?.revoke()
        keychain = KeychainManager(accountStorage: storage, loadLegacy: { nil }, deleteLegacy: {})
        state = IOSAuthenticationSessionState(storage: .live(keychain: keychain))
        _ = try await state.restore(intent: state.currentIntent)
        bind(fixture)
    }

    private func bind(_ fixture: RegistryFixture) {
        fixture.context = state.audioAuthorization.map { .init(authorization: $0, account: fixture.account) }
    }

    func provider(_ fixture: RegistryFixture,
                  boot: @escaping @Sendable () async throws -> UUID = IOSAudioBootWitness.read)
        -> IOSAudioAccountMembershipProvider {
        let state = state, keychain = keychain
        return IOSAudioAccountMembershipProvider(factory: fixture.factory,
            wall: { [clock = fixture.clock] in clock.wall },
            monotonic: { [clock = fixture.clock] in clock.monotonic },
            persistence: AudioMembershipPersistence(bootSessionID: boot,
                load: { try await state.loadAudioMembershipCheckpoint(for: $0.authorization, keychain: keychain) },
                save: { try await state.saveAudioMembershipCheckpoint($2, replacing: $1,
                    for: $0.authorization, keychain: keychain) },
                beginObservation: { try await state.beginAudioMembershipObservation(for: $0.authorization,
                    keychain: keychain) }))
    }
}

private final class RegistryCounter: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: 0)
    func increment() -> Int { value.withLock { $0 += 1; return $0 } }
}

private final class RegistryClock: Sendable {
    private let value = OSAllocatedUnfairLock(initialState: (Int64(1_000_000), ContinuousClock.now))
    var wall: Int64 { value.withLock { $0.0 } }
    var monotonic: ContinuousClock.Instant { value.withLock { $0.1 } }
    func advance(_ milliseconds: Int64) {
        value.withLock { $0.0 += milliseconds; $0.1 = $0.1.advanced(by: .milliseconds(milliseconds)) }
    }
}

@MainActor
private final class RegistryGate<Value: Sendable> {
    private(set) var arrived = false
    private var continuation: CheckedContinuation<Value, Error>?
    private var result: Result<Value, Error>?
    func wait() async throws -> Value {
        arrived = true
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ result: Result<Value, Error>) {
        guard self.result == nil else { return }
        self.result = result; continuation?.resume(with: result); continuation = nil
    }
    func waitForArrival() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !arrived {
            guard ContinuousClock.now < deadline else { throw RegistryTestError.timeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private enum RegistryTestError: Error { case unexpectedRequest, timeout }

@MainActor
private final class RegistryBackend {
    var lists: [@MainActor (ProtocolIdentityBindingCompat) async throws -> AccountDeviceListSnapshot] = []
    var heartbeats: [@MainActor () async throws -> SignalServerClient.PresenceRegisterResponseBody] = []
    var removals: [@MainActor (AccountDeviceRecord, String) async throws -> Void] = []
    var listCalls = 0, heartbeatCalls = 0, removalCalls = 0
}

@MainActor
private final class RegistryClient: IOSAudioAccountRegistryClient {
    let frozen: SignalServerClientCompat.FrozenAccountRequest
    let backend: RegistryBackend
    init(frozen: SignalServerClientCompat.FrozenAccountRequest, backend: RegistryBackend) {
        self.frozen = frozen; self.backend = backend
    }
    func listAccountDevices(binding: ProtocolIdentityBindingCompat) async throws -> AccountDeviceListSnapshot {
        try frozen.requireCurrent(); backend.listCalls += 1
        guard !backend.lists.isEmpty else { throw RegistryTestError.unexpectedRequest }
        let operation = backend.lists.removeFirst()
        let result = try await operation(binding)
        try frozen.requireCurrent()
        return result
    }
    func registerPresence(binding: ProtocolIdentityBindingCompat, report: AccountDevicePresenceReport) async throws -> SignalServerClient.PresenceRegisterResponseBody {
        try frozen.requireCurrent(); backend.heartbeatCalls += 1
        guard !backend.heartbeats.isEmpty else { throw RegistryTestError.unexpectedRequest }
        let operation = backend.heartbeats.removeFirst()
        let result = try await operation()
        try frozen.requireCurrent()
        return result
    }
    func removeAccountDevice(binding: ProtocolIdentityBindingCompat, target: AccountDeviceRecord, expectedAccountScope: String) async throws {
        try frozen.requireCurrent()
        guard expectedAccountScope == frozen.account.serverScope else { throw AudioMembershipError.scopeMismatch }
        backend.removalCalls += 1
        guard !backend.removals.isEmpty else { throw RegistryTestError.unexpectedRequest }
        let operation = backend.removals.removeFirst()
        try await operation(target, expectedAccountScope)
        try frozen.requireCurrent()
    }
}
