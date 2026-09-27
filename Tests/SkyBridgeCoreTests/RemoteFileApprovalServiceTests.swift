import Foundation
import XCTest
import SkyBridgeProtocolCore

@MainActor
final class RemoteFileApprovalServiceTests: XCTestCase {
    @MainActor final class Fixture {
        let local = identity("00000000-0000-0000-0000-000000000001", byte: 1)
        let peer = identity("00000000-0000-0000-0000-000000000002", byte: 2)
        let registry = RemoteFileApprovalRegistry()
        var grants: [String: Bool] = [:]
        var trust = true
        var decisions: [Bool] = []
        var approvals = 0
        var supported = true
        var authorizeDecision = HandshakeConfigurationService.Decision.alwaysAllow
        lazy var service = HandshakeConfigurationService(identity: { self.local }, trusted: { _ in self.trust },
            verify: { data, signature, _ in signature == data }, sign: { $0 },
            snapshot: { throw HandshakeConfigurationError.profileUnavailable },
            apply: { _, _, _ in throw HandshakeConfigurationError.applyFailed },
            readGrant: { self.grants[$0] ?? false }, writeGrant: { self.grants[$0] = $1 },
            approve: { _, _ in .reject }, approveFiles: { _ in self.approvals += 1; return self.authorizeDecision },
            fileApprovalSupported: supported, fileRegistry: registry)
        static func identity(_ id: String, byte: UInt8) -> HandshakeManagementIdentity {
            let key = Data(repeating: byte, count: 1952)
            return .init(deviceID: id, algorithm: "ML-DSA-65", publicKey: key,
                         fingerprint: ProtocolIdentityBinding.computeFingerprint(algorithm: .mlDSA65, publicKeyBytes: key))
        }
        func request(_ action: HandshakeConfigurationRequest.Action, previous: HandshakeConfigurationResponse? = nil,
                     decision: RemoteFileApprovalDecision? = nil) throws -> HandshakeConfigurationRequest {
            var request = HandshakeConfigurationRequest(action: action, requester: peer,
                targetDeviceID: local.deviceID, targetFingerprint: local.fingerprint,
                challenge: previous?.challenge, fileDecision: decision)
            request.signature = try request.signingData()
            return request
        }
        func call(_ action: HandshakeConfigurationRequest.Action, previous: HandshakeConfigurationResponse? = nil,
                  decision: RemoteFileApprovalDecision? = nil) async throws -> HandshakeConfigurationResponse {
            let request = try request(action, previous: previous, decision: decision)
            let response = try await service.handle(request)
            try response.validate(for: request)
            return response
        }
        func prompt() throws -> RemoteFileApprovalPrompt {
            let binding = try RemoteFileApprovalBinding(transferID: UUID().uuidString, senderDeviceID: peer.deviceID,
                senderFingerprint: peer.fingerprint,
                sessionReference: XCTUnwrap(P2PEvidenceReference.sessionIncarnation(sessionID: "file-approval-test-session", transcriptHash: Data(repeating: 8, count: 32))),
                metadataDigest: String(repeating: "a", count: 64), fileName: "test.txt", fileSize: 3, fileSHA256: String(repeating: "b", count: 64))
            return try registry.register(binding: binding, nativeRequestID: UUID(), expiresAt: Date().addingTimeInterval(60),
                revalidate: {}, resolve: { self.decisions.append($0); return true })
        }
    }
    func testHandshakeGrantDoesNotAuthorizeFilesAndPollingDoesNotExhaustNonceQuota() async throws {
        let f = Fixture(); f.grants[f.peer.grantKey] = true
        _ = try f.prompt()
        var challenge: Data?
        for _ in 0..<20 {
            let status = try await f.call(.fileStatus)
            XCTAssertEqual(status.fileApproval?.authorized, false); XCTAssertEqual(status.fileApproval?.pending.count, 0)
            if let challenge { XCTAssertEqual(status.challenge, challenge) }
            challenge = status.challenge
        }
        XCTAssertEqual(f.approvals, 0); XCTAssertTrue(f.decisions.isEmpty)
    }
    func testSeparateGrantAndExactDecisionAndReplay() async throws {
        let f = Fixture(), prompt = try f.prompt()
        let status = try await f.call(.fileStatus)
        let granted = try await f.call(.fileAuthorize, previous: status)
        XCTAssertEqual(granted.fileApproval?.authorized, true); XCTAssertFalse(granted.managementAuthorized)
        XCTAssertNil(f.grants[f.peer.grantKey]); XCTAssertEqual(f.approvals, 1)
        let decision = RemoteFileApprovalDecision(prompt: prompt, allow: true)
        let applied = try await f.call(.fileDecide, decision: decision)
        XCTAssertNil(applied.fileApprovalError); XCTAssertEqual(f.decisions, [true])
        let replay = try await f.call(.fileDecide, decision: decision)
        XCTAssertEqual(replay.fileApprovalError, .stale); XCTAssertEqual(f.decisions, [true])
    }
    func testGrantRevocationLeavesNoAuthorityToDecideAnExistingPrompt() async throws {
        let f = Fixture(), prompt = try f.prompt()
        f.grants["file-approval:v1:" + f.peer.grantKey] = true
        let status = try await f.call(.fileStatus)
        let revoked = try await f.call(.fileRevoke, previous: status)
        XCTAssertEqual(revoked.fileApproval?.authorized, false)
        let answer = try await f.call(.fileDecide, decision: .init(prompt: prompt, allow: true))
        XCTAssertEqual(answer.fileApprovalError, .unauthorized); XCTAssertTrue(f.decisions.isEmpty)
    }
    func testRejectDoesNotGrantAndUnsupportedHostDoesNotAdvertiseUsableApproval() async throws {
        let f = Fixture(); f.authorizeDecision = .reject
        let status = try await f.call(.fileStatus)
        let denied = try await f.call(.fileAuthorize, previous: status)
        XCTAssertEqual(denied.fileApprovalError, .unauthorized); XCTAssertTrue(f.grants.isEmpty)
        let old = Fixture(); old.supported = false
        let unavailable = try await old.call(.fileStatus)
        XCTAssertEqual(unavailable.fileApprovalError, .unavailable); XCTAssertNil(unavailable.fileApproval)
    }
    func testTenMinuteGrantDoesNotPersistAcrossServiceRestart() async throws {
        let f = Fixture(); f.authorizeDecision = .allowOnce
        let status = try await f.call(.fileStatus)
        let grant = try await f.call(.fileAuthorize, previous: status)
        XCTAssertEqual(grant.fileApproval?.authorized, true); XCTAssertTrue(f.grants.isEmpty)
        let restarted = Fixture(); restarted.grants = f.grants
        let check = try await restarted.call(.fileStatus)
        XCTAssertEqual(check.fileApproval?.authorized, false)
    }
    func testNativeSettingsRevocationClearsTenMinuteGrantImmediately() async throws {
        let f = Fixture(); f.authorizeDecision = .allowOnce
        let status = try await f.call(.fileStatus)
        _ = try await f.call(.fileAuthorize, previous: status)
        try f.service.revokeFileManagement(grantKey: f.peer.grantKey)
        let revoked = try await f.call(.fileStatus)
        XCTAssertEqual(revoked.fileApproval?.authorized, false)
    }

}
