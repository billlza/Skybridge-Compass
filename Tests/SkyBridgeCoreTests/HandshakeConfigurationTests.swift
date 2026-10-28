import Foundation
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

/// These tests exercise the shared authorization/CAS/replay state machine with
/// injected deterministic signing. They do not claim ML-DSA or device acceptance.
@MainActor
final class HandshakeConfigurationTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let local = identity(1)
        let peer = identity(2)
        var state = snapshot()
        var trust = true
        var grant = false
        var decision = HandshakeConfigurationService.Decision.allowOnce
        var approvals = 0
        var applies = 0
        var storageFails = false
        var applyFailure: HandshakeConfigurationError?
        var mutateDuringApproval = false
        var revokeDuringPreparation = false
        var untrustDuringPreparation = false
        lazy var service = HandshakeConfigurationService(
            identity: { self.local }, trusted: { _ in self.trust },
            verify: { data, signature, _ in signature == Self.testSignature(data) },
            sign: { Self.testSignature($0) },
            snapshot: { self.state },
            apply: { profile, revision, revalidate in
                if self.revokeDuringPreparation { self.grant = false }
                if self.untrustDuringPreparation { self.trust = false }
                try await revalidate()
                guard self.state.revision == revision else { throw HandshakeConfigurationError.revisionChanged }
                self.applies += 1
                if let failure = self.applyFailure { throw failure }
                self.state.configuredProfile = profile
                self.state.providerSuite = profile == .xwing ? "X-Wing" : (profile == .qperiapt ? "Q-Periapt-ABI2-PolicyBound" : "ML-KEM-768")
                self.state.revision = UUID().uuidString
                return self.state
            },
            readGrant: { _ in self.grant },
            writeGrant: { _, value in
                if self.storageFails { throw HandshakeConfigurationError.storageUnavailable }
                self.grant = value
            },
            approve: { _, _ in
                self.approvals += 1
                if self.mutateDuringApproval { self.state.revision = UUID().uuidString }
                return self.decision
            })
        nonisolated static func testSignature(_ data: Data) -> Data { Data(HandshakeConfigurationWire.hash(data).utf8) }
        static func identity(_ n: UInt8) -> HandshakeManagementIdentity {
            let key = Data(repeating: n, count: 1952)
            return .init(deviceID: n == 1 ? "00000000-0000-0000-0000-000000000001" : "00000000-0000-0000-0000-000000000002",
                         algorithm: "ML-DSA-65", publicKey: key, fingerprint: ProtocolIdentityBinding.computeFingerprint(algorithm: .mlDSA65, publicKeyBytes: key))
        }
        static func snapshot() -> HandshakeConfigurationSnapshot {
            .init(revision: UUID().uuidString, configuredProfile: .mlkem, providerSuite: "ML-KEM-768",
                  options: HandshakeProfile.allCases.map { .init($0, selectable: $0 != .classic) }, busy: false)
        }
        func request(_ action: HandshakeConfigurationRequest.Action = .status, previous: HandshakeConfigurationResponse? = nil,
                     profile: HandshakeProfile? = nil) throws -> HandshakeConfigurationRequest {
            var request = HandshakeConfigurationRequest(action: action, requester: peer,
                targetDeviceID: local.deviceID, targetFingerprint: local.fingerprint, profile: profile,
                expectedRevision: action == .apply ? previous?.snapshot?.revision : nil, challenge: previous?.challenge)
            request.signature = Self.testSignature(try request.signingData())
            return request
        }
        func status() async throws -> HandshakeConfigurationResponse { try await service.handle(request()) }
    }

    func testSignedStatusAndWireRoundTripDoNotGrantOrApply() async throws {
        let f = Fixture(), request = try Fixture().request()
        let response = try await f.service.handle(request)
        try response.validate(for: request)
        XCTAssertFalse(response.managementAuthorized)
        XCTAssertEqual(response.challenge?.count, 32)
        XCTAssertEqual(f.applies, 0); XCTAssertEqual(f.approvals, 0)
        let bytes = try JSONEncoder().encode(AppMessage.handshakeConfigurationRequest(request))
        XCTAssertEqual(try AppMessage.decodeWireMessage(from: bytes), .handshakeConfigurationRequest(request))
    }
    func testAllowOnceDoesNotPersistAndChallengeCannotReplay() async throws {
        let f = Fixture(), status = try await f.status()
        let request = try f.request(.apply, previous: status, profile: .xwing)
        let response = try await f.service.handle(request)
        try response.validate(for: request)
        XCTAssertTrue(response.applied); XCTAssertFalse(f.grant); XCTAssertEqual(f.approvals, 1)
        let replay = try await f.service.handle(request)
        XCTAssertEqual(replay.error, .replayed); XCTAssertEqual(f.applies, 1)
    }
    func testRepeatedStatusKeepsOneRevisionBoundSingleUseChallenge() async throws {
        let f = Fixture(), first = try await f.status()
        for _ in 0..<24 {
            let status = try await f.status()
            XCTAssertNil(status.error)
            XCTAssertEqual(status.challenge, first.challenge)
        }
        let apply = try f.request(.apply, previous: first, profile: .xwing)
        let applied = try await f.service.handle(apply)
        XCTAssertTrue(applied.applied)
        let replay = try await f.service.handle(apply)
        XCTAssertEqual(replay.error, .replayed)
        let next = try await f.status()
        XCTAssertNotEqual(next.challenge, first.challenge)
        XCTAssertEqual(f.applies, 1)
    }
    func testStatusDoesNotReuseChallengeAfterRevisionChangeOrExpiry() async throws {
        let f = Fixture(), first = try await f.status()
        f.state.revision = UUID().uuidString
        let revised = try await f.status()
        XCTAssertNotEqual(revised.challenge, first.challenge)
        let stale = try await f.service.handle(f.request(.apply, previous: first, profile: .xwing))
        XCTAssertEqual(stale.error, .revisionChanged)
        let future = Date().addingTimeInterval(121)
        var request = HandshakeConfigurationRequest(action: .status, requester: f.peer,
            targetDeviceID: f.local.deviceID, targetFingerprint: f.local.fingerprint, now: future)
        request.signature = Fixture.testSignature(try request.signingData())
        let expired = try await f.service.handle(request, now: future)
        XCTAssertNil(expired.error)
        XCTAssertNotEqual(expired.challenge, revised.challenge)
        XCTAssertEqual(f.applies, 0)
    }
    func testRestartInvalidatesOutstandingChallenge() async throws {
        let first = Fixture(), status = try await first.status()
        let restarted = Fixture()
        restarted.state = first.state
        let response = try await restarted.service.handle(first.request(.apply, previous: status, profile: .xwing))
        XCTAssertEqual(response.error, .replayed); XCTAssertEqual(restarted.applies, 0)
    }
    func testPersistentGrantReusesOnlyAfterSuccessfulStorageAndCanRevoke() async throws {
        let f = Fixture(); f.decision = .alwaysAllow
        var status = try await f.status()
        let first = try await f.service.handle(f.request(.apply, previous: status, profile: .xwing))
        XCTAssertTrue(first.applied); XCTAssertTrue(f.grant)
        status = try await f.status()
        let second = try await f.service.handle(f.request(.apply, previous: status, profile: .mlkem))
        XCTAssertTrue(second.applied); XCTAssertEqual(f.approvals, 1)
        status = try await f.status()
        let revoked = try await f.service.handle(f.request(.revoke, previous: status))
        XCTAssertNil(revoked.error); XCTAssertFalse(revoked.managementAuthorized); XCTAssertFalse(f.grant)
    }
    func testGrantStorageFailurePreventsConfigurationWrite() async throws {
        let f = Fixture(); f.decision = .alwaysAllow; f.storageFails = true
        let status = try await f.status()
        let response = try await f.service.handle(f.request(.apply, previous: status, profile: .xwing))
        XCTAssertEqual(response.error, .storageUnavailable); XCTAssertEqual(f.applies, 0)
    }
    func testClassicAndBusyAreRefusedBeforePrompt() async throws {
        for (profile, busy, expected) in [(HandshakeProfile.classic, false, HandshakeConfigurationError.classicDisabled), (.xwing, true, .transferActive)] {
            let f = Fixture(); f.state.busy = busy
            let status = try await f.status()
            let response = try await f.service.handle(f.request(.apply, previous: status, profile: profile))
            XCTAssertEqual(response.error, expected); XCTAssertEqual(f.approvals, 0); XCTAssertEqual(f.applies, 0)
        }
    }
    func testConfigurationChangeDuringConsentDoesNotOverwrite() async throws {
        let f = Fixture(); f.mutateDuringApproval = true
        let status = try await f.status()
        let response = try await f.service.handle(f.request(.apply, previous: status, profile: .xwing))
        XCTAssertEqual(response.error, .revisionChanged); XCTAssertEqual(f.applies, 0)
        XCTAssertEqual(response.snapshot?.revision, f.state.revision)
    }
    func testUntrustedOrTamperedRequestDoesNotPrompt() async throws {
        let f = Fixture(); f.trust = false
        do { _ = try await f.status(); XCTFail("untrusted request accepted") }
        catch { XCTAssertEqual(error as? HandshakeConfigurationError, .peerUntrusted) }
        f.trust = true
        var request = try f.request(); request.signature = Data([1])
        do { _ = try await f.service.handle(request); XCTFail("tampered request accepted") }
        catch { XCTAssertEqual(error as? HandshakeConfigurationError, .signatureInvalid) }
        XCTAssertEqual(f.approvals, 0); XCTAssertEqual(f.applies, 0)
    }
    func testRefusalAndProviderFailureCannotClaimApplied() async throws {
        let f = Fixture(); f.decision = .reject
        var status = try await f.status()
        let refusal = try await f.service.handle(f.request(.apply, previous: status, profile: .xwing))
        XCTAssertEqual(refusal.error, .authorizationDenied); XCTAssertFalse(refusal.applied)
        f.decision = .allowOnce; f.applyFailure = .rollbackFailed
        status = try await f.status()
        let failed = try await f.service.handle(f.request(.apply, previous: status, profile: .xwing))
        XCTAssertEqual(failed.error, .rollbackFailed); XCTAssertFalse(failed.applied)
    }
    func testResponseBindsRequestAndRequiresActualSuiteReadback() async throws {
        let f = Fixture(), request = try f.request()
        var response = try await f.service.handle(request)
        response.requestID = UUID()
        XCTAssertThrowsError(try response.validate(for: request))
        let status = try await f.status(), apply = try f.request(.apply, previous: status, profile: .xwing)
        response = try await f.service.handle(apply)
        response.snapshot?.providerSuite = "ML-KEM-768"
        XCTAssertThrowsError(try response.validate(for: apply))
    }
    func testRevocationDuringProviderPreparationPreventsCommit() async throws {
        let f = Fixture(); f.grant = true; f.revokeDuringPreparation = true
        let status = try await f.status()
        let response = try await f.service.handle(f.request(.apply, previous: status, profile: .xwing))
        XCTAssertEqual(response.error, .authorizationDenied); XCTAssertEqual(f.applies, 0)
    }
    func testUnpairingDuringProviderPreparationPreventsCommit() async throws {
        let f = Fixture(); f.grant = true; f.untrustDuringPreparation = true
        let status = try await f.status()
        let response = try await f.service.handle(f.request(.apply, previous: status, profile: .xwing))
        XCTAssertEqual(response.error, .identityMismatch); XCTAssertEqual(f.applies, 0)
    }
    func testExtremeTimestampsAreRejectedWithoutIntegerOverflow() throws {
        let f = Fixture(); var request = try f.request()
        request.issuedAtMilliseconds = .max; request.expiresAtMilliseconds = .min
        XCTAssertThrowsError(try request.validate())
        request.issuedAtMilliseconds = 1; request.expiresAtMilliseconds = .max
        XCTAssertThrowsError(try request.validate())
    }
    func testGrantIsBoundToFullIdentityAndMalformedDataFailsClosed() throws {
        let data = try JSONEncoder().encode(HandshakeManagementGrant(identityKey: "peer:old", allowed: true))
        XCTAssertThrowsError(try HandshakeManagementGrant.decode(data, key: "peer:new"))
        XCTAssertThrowsError(try HandshakeManagementGrant.decode(Data([0]), key: "peer:old"))
        XCTAssertFalse(try HandshakeManagementGrant.decode(nil, key: "peer:old"))
    }
    func testOperatorParametersRejectIncompleteOrAmbiguousTargetsAndMistypedFlags() throws {
        let invalid: [[String: Any]] = [
            ["profile":"xwing", "scope":"both"],
            ["profile":"xwing", "reconnect":"true"],
            ["profile":"xwing", "scope":123],
            ["profile":"xwing", "device_ref":42],
            ["profile":"xwing", "peer_id":"00000000-0000-0000-0000-000000000001"],
            ["profile":"unknown"],
            ["profile":"xwing", "udid":"00008140-000E788401C0801C"]
        ]
        for values in invalid {
            let params = try JSONDecoder().decode(CrossnetControlParams.self, from: JSONSerialization.data(withJSONObject: values))
            XCTAssertThrowsError(try OperatorHandshakeRequest(action: .set, params: params), "accepted \(values)")
        }
    }
    func testExplicitUSBTargetNeedsNoDiscoveryReference() throws {
        let values: [String: Any] = ["profile":"qperiapt","scope":"both","reconnect":true,
            "udid":"00008140-000E788401C0801C","peer_id":"00000000-0000-0000-0000-000000000001",
            "expected_fingerprint":String(repeating:"a",count:64)]
        let params = try JSONDecoder().decode(CrossnetControlParams.self, from: JSONSerialization.data(withJSONObject: values))
        let request = try OperatorHandshakeRequest(action:.set,params:params)
        XCTAssertNil(request.deviceRef); XCTAssertNotNil(request.usb); XCTAssertTrue(request.reconnect)
    }

    func testManagementIdentityUsesExistingAlgorithmBoundFingerprint() throws {
        let key = Data(repeating: 3, count: 1952)
        let fingerprint = ProtocolIdentityBinding.computeFingerprint(algorithm: .mlDSA65, publicKeyBytes: key)
        let identity = HandshakeManagementIdentity(deviceID: "00000000-0000-0000-0000-000000000001",
            algorithm: "ML-DSA-65", publicKey: key, fingerprint: fingerprint)
        XCTAssertNoThrow(try identity.validate())
        var unbound = identity; unbound.fingerprint = HandshakeConfigurationWire.hash(key)
        XCTAssertThrowsError(try unbound.validate())
    }
    func testManagementCanonicalizesProductIDPrefixWithoutAcceptingEndpointAlias() throws {
        let key = Data(repeating: 3, count: 1952)
        let identity = HandshakeManagementIdentity(deviceID: "id:00000000-0000-0000-0000-000000000001",
            algorithm: "ML-DSA-65", publicKey: key,
            fingerprint: ProtocolIdentityBinding.computeFingerprint(algorithm: .mlDSA65, publicKeyBytes: key))
        XCTAssertEqual(identity.deviceID, "00000000-0000-0000-0000-000000000001")
        XCTAssertNoThrow(try identity.validate())
        let request = HandshakeConfigurationRequest(action: .status, requester: identity,
            targetDeviceID: "id:00000000-0000-0000-0000-000000000002", targetFingerprint: String(repeating:"b",count:64))
        XCTAssertEqual(request.targetDeviceID, "00000000-0000-0000-0000-000000000002")
        XCTAssertNoThrow(try request.validate())
        var bad = identity; bad.deviceID = "host:00000000-0000-0000-0000-000000000001"
        XCTAssertThrowsError(try bad.validate())
    }

}
