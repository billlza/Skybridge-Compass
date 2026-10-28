import Foundation
import XCTest
@testable import SkyBridgeCompass_iOS

final class P2PProtocolIdentityBindingCandidateDisplayCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testCandidateDisplaysBeforeAnyConfirmWithoutConsumingTheTransaction() throws {
        let coordinator = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        let candidate = fixture()
        let prepared = try XCTUnwrap(coordinator.prepare(candidate, isReplay: false, hasPendingApproval: false, now: now))
        let display = try XCTUnwrap(coordinator.displayAfterSend(id: prepared.id, now: now))
        XCTAssertEqual(display.candidate.verificationCode, candidate.verificationCode)
        XCTAssertEqual(display.candidate.sasTranscriptHashHex, candidate.sasTranscriptHashHex)
        XCTAssertEqual(try confirm(coordinator, candidate), prepared)
    }

    @MainActor
    func testCandidateReplayUsesSamePresentationAndCannotOverwriteApproval() throws {
        let coordinator = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        let candidate = fixture()
        let prepared = try XCTUnwrap(coordinator.prepare(candidate, isReplay: false, hasPendingApproval: false, now: now))
        XCTAssertEqual(try coordinator.prepare(candidate, isReplay: true, hasPendingApproval: true, now: now), prepared)
        _ = try confirm(coordinator, candidate)
        XCTAssertNil(coordinator.displayAfterSend(id: prepared.id, now: now))
        XCTAssertFalse(coordinator.dismissCandidate(id: prepared.id))
    }

    @MainActor
    func testBusyDisplayAndUnrelatedApprovalCannotBeReplaced() throws {
        let coordinator = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        let first = try coordinator.prepare(fixture(), isReplay: false, hasPendingApproval: false, now: now)
        XCTAssertThrowsError(try coordinator.prepare(fixture(), isReplay: false, hasPendingApproval: false, now: now)) {
            XCTAssertEqual($0 as? P2PProtocolIdentityBindingCandidateDisplayCoordinator.Failure, .busy)
        }
        XCTAssertEqual(coordinator.current, first)
        let other = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        XCTAssertThrowsError(try other.prepare(fixture(), isReplay: false, hasPendingApproval: true, now: now))
        XCTAssertNil(other.current)
    }

    @MainActor
    func testChangedTranscriptCannotClaimCurrentComparison() throws {
        let coordinator = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        let candidate = fixture()
        let prepared = try coordinator.prepare(candidate, isReplay: false, hasPendingApproval: false, now: now)
        for changedField in 0..<4 {
            XCTAssertThrowsError(try coordinator.beginConfirmation(
                transactionId: changedField == 0 ? UUID() : candidate.transactionId,
                requestHashHex: changedField == 1 ? "other" : candidate.requestHashHex,
                candidateHashHex: changedField == 2 ? "other" : candidate.candidateHashHex,
                sasTranscriptHashHex: changedField == 3 ? "other" : candidate.sasTranscriptHashHex,
                now: now
            ))
            XCTAssertEqual(coordinator.current, prepared)
        }
        XCTAssertNotNil(try confirm(coordinator, candidate))
    }

    @MainActor
    func testExpiredCandidateCannotDisplayOrEnterApproval() throws {
        let coordinator = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        let candidate = fixture()
        let prepared = try XCTUnwrap(coordinator.prepare(candidate, isReplay: false, hasPendingApproval: false, now: now))
        XCTAssertNil(coordinator.displayAfterSend(id: prepared.id, now: candidate.expiresAt))
        XCTAssertThrowsError(try coordinator.beginConfirmation(
            transactionId: candidate.transactionId, requestHashHex: candidate.requestHashHex,
            candidateHashHex: candidate.candidateHashHex, sasTranscriptHashHex: candidate.sasTranscriptHashHex,
            now: candidate.expiresAt
        ))
        XCTAssertTrue(coordinator.expire(id: prepared.id, now: candidate.expiresAt))
        XCTAssertNil(coordinator.current)
        XCTAssertThrowsError(try coordinator.prepare(candidate, isReplay: false, hasPendingApproval: false, now: candidate.expiresAt))
    }

    @MainActor
    func testDismissedOrFailedSendCannotBeRevivedByCandidateReplay() throws {
        let coordinator = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        let candidate = fixture()
        let prepared = try XCTUnwrap(coordinator.prepare(candidate, isReplay: false, hasPendingApproval: false, now: now))
        XCTAssertTrue(coordinator.dismissCandidate(id: prepared.id))
        XCTAssertNil(try coordinator.prepare(candidate, isReplay: true, hasPendingApproval: false, now: now))
        XCTAssertThrowsError(try confirm(coordinator, candidate))
    }

    @MainActor
    func testLateSendFailureExpiryAndFinishCannotAffectReplacement() throws {
        let coordinator = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        let first = try XCTUnwrap(coordinator.prepare(fixture(), isReplay: false, hasPendingApproval: false, now: now))
        XCTAssertTrue(coordinator.dismissCandidate(id: first.id))
        let replacement = try coordinator.prepare(fixture(), isReplay: false, hasPendingApproval: false, now: now)
        XCTAssertFalse(coordinator.dismissCandidate(id: first.id))
        XCTAssertFalse(coordinator.expire(id: first.id, now: now.addingTimeInterval(500)))
        XCTAssertFalse(coordinator.finish(id: first.id))
        XCTAssertEqual(coordinator.current, replacement)
    }

    @MainActor
    func testOnlyOneVerifiedConfirmCanClaimTheCandidate() throws {
        let coordinator = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        let candidate = fixture()
        let prepared = try XCTUnwrap(coordinator.prepare(candidate, isReplay: false, hasPendingApproval: false, now: now))
        XCTAssertEqual(try confirm(coordinator, candidate), prepared)
        XCTAssertThrowsError(try confirm(coordinator, candidate))
        XCTAssertTrue(coordinator.finish(id: prepared.id))
        XCTAssertNil(coordinator.current)
    }

    @MainActor
    func testExpiryTaskRetiresOnlyItsOwnDisplay() async throws {
        let coordinator = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        let candidate = fixture(expiresAt: Date().addingTimeInterval(0.02))
        let prepared = try XCTUnwrap(coordinator.prepare(candidate, isReplay: false, hasPendingApproval: false))
        let expired = expectation(description: "candidate display expired")
        coordinator.scheduleExpiry(for: prepared) { id in
            XCTAssertEqual(id, prepared.id)
            expired.fulfill()
        }
        let result = await XCTWaiter.fulfillment(of: [expired], timeout: 1)
        XCTAssertEqual(result, .completed)
        XCTAssertNil(coordinator.current)
    }

    @MainActor
    func testReplacingDisplayCancelsOldExpiryCallback() async throws {
        let coordinator = P2PProtocolIdentityBindingCandidateDisplayCoordinator()
        let old = try XCTUnwrap(coordinator.prepare(fixture(expiresAt: Date().addingTimeInterval(0.02)),
            isReplay: false, hasPendingApproval: false))
        var expirations = 0
        coordinator.scheduleExpiry(for: old) { _ in expirations += 1 }
        XCTAssertTrue(coordinator.dismissCandidate(id: old.id))
        let replacement = try coordinator.prepare(fixture(expiresAt: Date().addingTimeInterval(10)),
            isReplay: false, hasPendingApproval: false)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(expirations, 0)
        XCTAssertEqual(coordinator.current, replacement)
    }

    private func fixture(expiresAt: Date? = nil) -> P2PProtocolIdentityBindingCandidateDisplayCoordinator.Candidate {
        .init(transactionId: UUID(), requestHashHex: String(repeating: "a", count: 64),
              candidateHashHex: String(repeating: "b", count: 64), sasTranscriptHashHex: String(repeating: "c", count: 64),
              requesterDeviceId: "test-peer", requesterFingerprint: String(repeating: "d", count: 64),
              verificationCode: "000000", expiresAt: expiresAt ?? now.addingTimeInterval(300))
    }

    @MainActor
    private func confirm(
        _ coordinator: P2PProtocolIdentityBindingCandidateDisplayCoordinator,
        _ candidate: P2PProtocolIdentityBindingCandidateDisplayCoordinator.Candidate
    ) throws -> P2PProtocolIdentityBindingCandidateDisplayCoordinator.Presentation {
        try coordinator.beginConfirmation(transactionId: candidate.transactionId,
            requestHashHex: candidate.requestHashHex, candidateHashHex: candidate.candidateHashHex,
            sasTranscriptHashHex: candidate.sasTranscriptHashHex, now: now)
    }
}
