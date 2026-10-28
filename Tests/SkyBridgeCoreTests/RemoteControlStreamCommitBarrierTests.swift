import Foundation
import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

private actor StreamCommitTestGate {
    private var released = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { if !released { await withCheckedContinuation { waiting.append($0) } } }
    func release() { released = true; let values = waiting; waiting = []; values.forEach { $0.resume() } }
}
private actor StreamCommitTestCompletion {
    var termination: RemoteDesktopSessionTermination?
    func record(_ value: RemoteDesktopSessionTermination?) { termination = value }
}
final class RemoteControlStreamCommitBarrierTests: XCTestCase, @unchecked Sendable {
    private func acknowledgement(version: Int? = 1) -> RemoteDesktopStreamConfigurationAcknowledgement {
        .init(acceptedAt: 1, transaction: .init(), streamRefreshToken: nil,
              audioEndpointPresent: false, screenFrameTransport: "sbrf-v1", sessionTerminationVersion: version)
    }
    func testEndWaitsForWrittenAckCommitInsteadOfUsingOldMainActorReceipt() async throws {
        let barrier = RemoteControlStreamCommitBarrier(), gate = StreamCommitTestGate()
        let entered = StreamCommitTestGate(), result = StreamCommitTestCompletion()
        let first = acknowledgement(), next = acknowledgement()
        try await barrier.acknowledge(first) {}
        let write = Task { try await barrier.acknowledge(next) { await entered.release(); await gate.wait() } }
        await entered.wait()
        barrier.closeAcknowledgementAdmission()
        let end = Task { let value = try await barrier.termination(reason: .userStopped); await result.record(value) }
        try await Task.sleep(for: .milliseconds(30))
        let pending = await result.termination; XCTAssertNil(pending)
        await gate.release(); try await write.value; try await end.value
        let completed = await result.termination
        XCTAssertEqual(completed?.transaction, next.transaction)
        XCTAssertNotEqual(completed?.transaction, first.transaction)
    }
    func testResetRejectsOldCompletionWithoutOverwritingReplacement() async throws {
        let barrier = RemoteControlStreamCommitBarrier(), gate = StreamCommitTestGate(), entered = StreamCommitTestGate()
        let old = acknowledgement(), replacement = acknowledgement()
        let write = Task { try await barrier.acknowledge(old) { await entered.release(); await gate.wait() } }
        await entered.wait(); barrier.reset()
        try await barrier.acknowledge(replacement) {}
        await gate.release()
        do { try await write.value; XCTFail("retired ACK committed") } catch is CancellationError {} catch { XCTFail("unexpected error") }
        let end = try await barrier.termination(reason: .userStopped)
        XCTAssertEqual(end?.transaction, replacement.transaction)
    }
    func testLocalEndClosesAdmissionAndLegacyReceiptDoesNotEnableNewEnum() async throws {
        let barrier = RemoteControlStreamCommitBarrier()
        try await barrier.acknowledge(acknowledgement(version: nil)) {}
        barrier.closeAcknowledgementAdmission()
        let end = try await barrier.termination(reason: .permissionRevoked); XCTAssertNil(end)
        do { try await barrier.acknowledge(acknowledgement()) {}; XCTFail("ACK admitted after local end") }
        catch RemoteControlStreamCommitBarrier.BoundaryError.notAcceptingAcknowledgements {}
        catch { XCTFail("unexpected error") }
    }
    func testFailedAckCannotBecomeSuccessfulTermination() async throws {
        enum Expected: Error { case writeFailure }
        let barrier = RemoteControlStreamCommitBarrier()
        do { try await barrier.acknowledge(acknowledgement()) { throw Expected.writeFailure }; XCTFail("write succeeded") }
        catch Expected.writeFailure {} catch { XCTFail("wrong failure") }
        do { _ = try await barrier.termination(reason: .userStopped); XCTFail("failed ACK became END") }
        catch Expected.writeFailure {} catch { XCTFail("wrong failure") }
    }
}
