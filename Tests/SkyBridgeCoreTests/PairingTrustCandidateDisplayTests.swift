import Foundation
import XCTest
@testable import SkyBridgeCore

@MainActor
final class PairingTrustCandidateDisplayTests: XCTestCase {
    private func request(_ name: String = "peer") -> PairingTrustApprovalService.Request {
        let fingerprint = String(repeating: "a", count: 64)
        return .init(
            peerEndpoint: "isolated-endpoint", declaredDeviceId: name,
            policyBindingKey: "PIB-1-peer|\(name)|ML-DSA-65|\(fingerprint)",
            displayName: "Isolated peer", protocolIdentityAlgorithm: "ML-DSA-65",
            protocolIdentityFingerprint: fingerprint, protocolIdentityTransactionId: UUID(),
            protocolIdentityRequestHashHex: String(repeating: "1", count: 64),
            protocolIdentityCandidateHashHex: String(repeating: "2", count: 64),
            protocolIdentitySASTranscriptHashHex: String(repeating: "3", count: 64), kemKeyCount: 0
        )
    }

    func testSavedAllowDisplaysThisExactRequestAndCodeWithoutChangingPolicy() async throws {
        let request = request()
        let service = PairingTrustApprovalService(policyForTesting: [try XCTUnwrap(request.policyBindingKey): .alwaysAllow])
        let decision = await service.decideProtocolIdentityBindingCandidate(for: request, verificationCode: "123456")
        XCTAssertEqual(decision, .alwaysAllow)
        XCTAssertEqual(service.pendingRequest, request)
        XCTAssertEqual(service.pendingVerificationCode, "123456")
        XCTAssertEqual(service.pendingDecision, .alwaysAllow)
        let policy = await service.persistedPolicyDecision(for: request)
        XCTAssertEqual(policy, .alwaysAllow)
    }

    func testSavedRejectDoesNotPublishVerificationCode() async throws {
        let request = request()
        let service = PairingTrustApprovalService(policyForTesting: [try XCTUnwrap(request.policyBindingKey): .reject])
        let decision = await service.decideProtocolIdentityBindingCandidate(for: request, verificationCode: "123456")
        XCTAssertEqual(decision, .reject)
        XCTAssertNil(service.pendingRequest)
        XCTAssertNil(service.pendingVerificationCode)
    }

    func testSavedAllowCannotOverwriteAnExistingCandidateDisplay() async throws {
        let request = request()
        let service = PairingTrustApprovalService(policyForTesting: [try XCTUnwrap(request.policyBindingKey): .alwaysAllow])
        service.showProtocolIdentityBindingCode(
            peerEndpoint: "old-endpoint", declaredDeviceId: "old-peer", displayName: "Other candidate display",
            verificationCode: "654321", protocolIdentityFingerprint: String(repeating: "b", count: 64)
        )
        let existing = service.pendingRequest
        let decision = await service.decideProtocolIdentityBindingCandidate(for: request, verificationCode: "123456")
        XCTAssertEqual(decision, .alwaysAllow, "A display-capacity refusal must not rewrite saved authorization.")
        XCTAssertEqual(service.pendingRequest, existing)
        XCTAssertEqual(service.pendingVerificationCode, "654321")
    }
    func testSavedAllowDoesNotReplaceAnUnresolvedManualApproval() async throws {
        let automatic = request("automatic"), manual = request("manual")
        let service = PairingTrustApprovalService(policyForTesting: [try XCTUnwrap(automatic.policyBindingKey): .alwaysAllow])
        let waiter = Task { await service.decideProtocolIdentityBindingCandidate(for: manual, verificationCode: "654321") }
        try await waitForDisplay(service, requestID: manual.id)
        let decision = await service.decideProtocolIdentityBindingCandidate(for: automatic, verificationCode: "123456")
        XCTAssertEqual(decision, .alwaysAllow)
        XCTAssertEqual(service.pendingRequest, manual)
        XCTAssertEqual(service.pendingVerificationCode, "654321")
        service.clearProtocolIdentityBindingCandidateDisplay(for: manual.id)
        XCTAssertEqual(service.pendingRequest, manual, "Automatic-display cleanup must not close a manual approval.")
        waiter.cancel()
        let result = await waiter.value
        XCTAssertEqual(result, .reject)
    }

    func testAnotherAutomaticTransactionCannotReplaceCurrentOwnerAndLateCleanupCannotClearNext() async throws {
        let first = request("first"), next = request("next")
        let service = PairingTrustApprovalService(policyForTesting: [
            try XCTUnwrap(first.policyBindingKey): .alwaysAllow,
            try XCTUnwrap(next.policyBindingKey): .alwaysAllow
        ])
        _ = await service.decideProtocolIdentityBindingCandidate(for: first, verificationCode: "123456")
        let updatedAt = service.pendingVerificationUpdatedAt
        _ = await service.decideProtocolIdentityBindingCandidate(for: first, verificationCode: "123456")
        XCTAssertEqual(service.pendingVerificationUpdatedAt, updatedAt)
        let busyDecision = await service.decideProtocolIdentityBindingCandidate(for: next, verificationCode: "654321")
        XCTAssertEqual(busyDecision, .alwaysAllow)
        XCTAssertEqual(service.pendingRequest, first)
        service.clearProtocolIdentityBindingCandidateDisplay(for: next.id)
        XCTAssertEqual(service.pendingRequest, first)
        service.clearProtocolIdentityBindingCandidateDisplay(for: first.id)
        _ = await service.decideProtocolIdentityBindingCandidate(for: next, verificationCode: "654321")
        service.clearProtocolIdentityBindingCandidateDisplay(for: first.id)
        XCTAssertEqual(service.pendingRequest, next)
        XCTAssertEqual(service.pendingVerificationCode, "654321")
        service.clearProtocolIdentityBindingCandidateDisplay(for: next.id)
        XCTAssertNil(service.pendingRequest)
        XCTAssertNil(service.pendingVerificationCode)
    }

    func testInformationalDisplayIsClearedOnSuccessfulScopeExit() async throws {
        let request = request()
        let service = PairingTrustApprovalService(policyForTesting: [try XCTUnwrap(request.policyBindingKey): .alwaysAllow])
        try await confirmedScope(service, request: request) {
            XCTAssertEqual(service.pendingRequest, request)
            XCTAssertEqual(service.pendingVerificationCode, "123456")
        }
        XCTAssertNil(service.pendingRequest)
        XCTAssertNil(service.pendingVerificationCode)
    }

    func testInformationalDisplayIsClearedOnFailedScopeExit() async throws {
        let request = request()
        let service = PairingTrustApprovalService(policyForTesting: [try XCTUnwrap(request.policyBindingKey): .alwaysAllow])
        do {
            try await confirmedScope(service, request: request) { throw ScopeFailure.expected }
            XCTFail("Expected the unchanged operation failure")
        } catch ScopeFailure.expected {
            XCTAssertNil(service.pendingRequest)
            XCTAssertNil(service.pendingVerificationCode)
        }
    }

    func testInformationalDisplayIsClearedOnCancelledScopeExit() async throws {
        let request = request()
        let service = PairingTrustApprovalService(policyForTesting: [try XCTUnwrap(request.policyBindingKey): .alwaysAllow])
        let task = Task {
            try await confirmedScope(service, request: request) {
                try await Task.sleep(for: .seconds(30))
            }
        }
        try await waitForDisplay(service, requestID: request.id)
        task.cancel()
        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertNil(service.pendingRequest)
            XCTAssertNil(service.pendingVerificationCode)
        }
    }

    private enum ScopeFailure: Error { case expected }

    /// Mirrors the single defer surrounding the real initiator's approval,
    /// confirm and final-ACK operation. The transport operation is isolated here.
    private func confirmedScope(
        _ service: PairingTrustApprovalService,
        request: PairingTrustApprovalService.Request,
        operation: () async throws -> Void
    ) async throws {
        defer { service.clearProtocolIdentityBindingCandidateDisplay(for: request.id) }
        let decision = await service.decideProtocolIdentityBindingCandidate(for: request, verificationCode: "123456")
        XCTAssertEqual(decision, .alwaysAllow)
        try await operation()
    }

    private func waitForDisplay(_ service: PairingTrustApprovalService, requestID: UUID) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while service.pendingRequest?.id != requestID {
            guard clock.now < deadline else { throw ScopeFailure.expected }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

}
