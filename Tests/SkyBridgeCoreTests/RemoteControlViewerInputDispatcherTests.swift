#if os(macOS)
import XCTest
@testable import SkyBridgeCore

@MainActor
final class RemoteControlViewerInputDispatcherTests: XCTestCase {
    func testRevokedInFlightSendRetainsItsDeadlineAndReportsTransportFailureOnce() async throws {
        let probe = SendProbe(blockSendNumber: 1)
        let failed = expectation(description: "A stalled revoked send still retires its exact transport")
        var failures: [RemoteControlViewerInputFailure] = []
        let dispatcher = RemoteControlViewerInputDispatcher(
            sendTimeout: .milliseconds(25),
            send: { try await probe.send($0) },
            onFailure: { failures.append($0); failed.fulfill() }
        )
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        await probe.waitForBlockedSend()
        dispatcher.revokeAccess()
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertEqual(failures.count, 1)
        guard let failure = failures.first, case .sendTimedOut = failure else {
            return XCTFail("Expected the original send deadline")
        }
        XCTAssertTrue(probe.hasBlockedSend)
        probe.resumeBlockedSend(throwing: SendProbe.Failure.transport)
        XCTAssertEqual(failures.count, 1)
    }

    func testCompletingRevokedInFlightSendCancelsDeadlineWithoutClosingViewer() async throws {
        let probe = SendProbe(blockSendNumber: 1)
        let completed = expectation(description: "The revoked in-flight send completed")
        let failed = expectation(description: "A completed revoked send must not fail the viewing transport")
        failed.isInverted = true
        let dispatcher = RemoteControlViewerInputDispatcher(
            sendTimeout: .milliseconds(30),
            send: { event in try await probe.send(event); completed.fulfill() },
            onFailure: { _ in failed.fulfill() }
        )
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        await probe.waitForBlockedSend()
        dispatcher.revokeAccess()
        probe.resumeBlockedSend()
        await fulfillment(of: [completed, failed], timeout: 0.1)
        XCTAssertEqual(probe.sent, [.key(.keyDown, 0)])
    }

    func testRevokedInFlightTransportErrorRemainsObservable() async throws {
        let probe = SendProbe(blockSendNumber: 1)
        let failed = expectation(description: "A transport failure remains distinct from an access change")
        let dispatcher = RemoteControlViewerInputDispatcher(
            send: { try await probe.send($0) },
            onFailure: { failure in
                guard case .sendFailed(let underlying) = failure, underlying is SendProbe.Failure else {
                    return XCTFail("Expected the underlying transport failure")
                }
                failed.fulfill()
            }
        )
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        await probe.waitForBlockedSend()
        dispatcher.revokeAccess()
        probe.resumeBlockedSend(throwing: SendProbe.Failure.transport)
        await fulfillment(of: [failed], timeout: 2)
    }

    func testRevocationDiscardsPendingInputsAndDoesNotSignalATransportFailure() async throws {
        let probe = SendProbe(blockSendNumber: 1)
        var failures: [RemoteControlViewerInputFailure] = []
        let dispatcher = RemoteControlViewerInputDispatcher(
            send: { try await probe.send($0) },
            onFailure: { failures.append($0) }
        )
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        await probe.waitForBlockedSend()
        try dispatcher.submitKeyboard(key(.keyDown, 1))
        let deactivation = Task { try await dispatcher.deactivate() }
        dispatcher.revokeAccess()
        do {
            try await deactivation.value
            XCTFail("A revoked grant cannot continue draining its input queue")
        } catch RemoteControlViewerInputFailure.accessRevoked {
            // An authenticated access change keeps the viewing transport alive.
        }
        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(probe.sent, [.key(.keyDown, 0)])
        XCTAssertThrowsError(try dispatcher.activate())
        XCTAssertThrowsError(try dispatcher.submitKeyboard(key(.keyDown, 2)))
        probe.resumeBlockedSend()
    }

    func testInactiveDispatcherRejectsInputAndCanBeReactivatedAfterRelease() async throws {
        let probe = SendProbe()
        let dispatcher = makeDispatcher(probe)

        XCTAssertThrowsError(try dispatcher.submitKeyboard(key(.keyDown, 0))) { error in
            guard case RemoteControlViewerInputFailure.inactive = error else {
                return XCTFail("Expected an inactive-input rejection, got \(error)")
            }
        }
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        try await dispatcher.deactivate()
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 1))
        try await dispatcher.deactivate()

        XCTAssertEqual(probe.sent, [.key(.keyDown, 0), .key(.keyUp, 0), .key(.keyDown, 1), .key(.keyUp, 1)])
    }

    func testMouseAndKeyboardKeepOrderAndOnlyConsecutivePendingMovesCoalesce() async throws {
        let probe = SendProbe(blockSendNumber: 1)
        let dispatcher = makeDispatcher(probe)
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        await probe.waitForBlockedSend()

        try dispatcher.submitMouse(mouse(.mouseMoved, 1))
        try dispatcher.submitMouse(mouse(.mouseMoved, 2))
        try dispatcher.submitMouse(mouse(.leftMouseDown, 3))
        try dispatcher.submitMouse(mouse(.mouseMoved, 4))
        try dispatcher.submitKeyboard(key(.keyUp, 0))
        try dispatcher.submitMouse(mouse(.mouseMoved, 5))
        try dispatcher.submitMouse(mouse(.mouseMoved, 6))
        try dispatcher.submitMouse(mouse(.leftMouseUp, 6))
        probe.resumeBlockedSend()
        try await dispatcher.deactivate()

        XCTAssertEqual(probe.sent, [
            .key(.keyDown, 0), .mouse(.mouseMoved, 2, 2),
            .mouse(.leftMouseDown, 3, 3), .mouse(.mouseMoved, 4, 4),
            .key(.keyUp, 0), .mouse(.mouseMoved, 6, 6), .mouse(.leftMouseUp, 6, 6)
        ])
    }

    func testDeactivateReleasesHeldInputsInReversePressOrderAtLatestPointerPosition() async throws {
        let probe = SendProbe()
        let dispatcher = makeDispatcher(probe)
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 56))
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        try dispatcher.submitMouse(mouse(.leftMouseDown, 10))
        try dispatcher.submitMouse(mouse(.rightMouseDown, 11))
        try dispatcher.submitMouse(mouse(.mouseMoved, 30))
        try await dispatcher.deactivate()

        XCTAssertEqual(probe.sent, [
            .key(.keyDown, 56), .key(.keyDown, 0), .key(.keyDown, 0),
            .mouse(.leftMouseDown, 10, 10), .mouse(.rightMouseDown, 11, 11),
            .mouse(.mouseMoved, 30, 30), .mouse(.rightMouseUp, 30, 30),
            .mouse(.leftMouseUp, 30, 30), .key(.keyUp, 0), .key(.keyUp, 56)
        ])
        let previousCount = probe.sent.count
        try await dispatcher.deactivate()
        XCTAssertEqual(probe.sent.count, previousCount, "Repeated focus loss must not release twice")
    }

    func testExplicitUpsClearHeldStateWithoutAdditionalSyntheticReleases() async throws {
        let probe = SendProbe()
        let dispatcher = makeDispatcher(probe)
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        try dispatcher.submitMouse(mouse(.rightMouseDown, 4))
        try dispatcher.submitKeyboard(key(.keyUp, 0))
        try dispatcher.submitMouse(mouse(.rightMouseUp, 4))
        try await dispatcher.deactivate()

        XCTAssertEqual(probe.sent, [
            .key(.keyDown, 0), .mouse(.rightMouseDown, 4, 4),
            .key(.keyUp, 0), .mouse(.rightMouseUp, 4, 4)
        ])
    }

    func testFocusCannotReactivateUntilTheReleaseSendCompletes() async throws {
        let probe = SendProbe(blockSendNumber: 2)
        let dispatcher = makeDispatcher(probe)
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        let deactivation = Task { try await dispatcher.deactivate() }
        await probe.waitForBlockedSend()

        XCTAssertEqual(probe.sent, [.key(.keyDown, 0), .key(.keyUp, 0)])
        XCTAssertThrowsError(try dispatcher.activate()) { error in
            guard case RemoteControlViewerInputFailure.deactivationInProgress = error else {
                return XCTFail("Activation must wait for release delivery, got \(error)")
            }
        }
        XCTAssertThrowsError(try dispatcher.submitKeyboard(key(.keyDown, 1)))
        probe.resumeBlockedSend()
        try await deactivation.value
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 1))
        try await dispatcher.deactivate()
        XCTAssertEqual(Array(probe.sent.suffix(2)), [.key(.keyDown, 1), .key(.keyUp, 1)])
    }

    func testConcurrentDeactivationCallersShareOneReleaseSequence() async throws {
        let probe = SendProbe(blockSendNumber: 2)
        let dispatcher = makeDispatcher(probe)
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        let first = Task { try await dispatcher.deactivate() }
        await probe.waitForBlockedSend()
        let second = Task { try await dispatcher.deactivate() }
        probe.resumeBlockedSend()
        try await first.value
        try await second.value

        XCTAssertEqual(probe.sent, [.key(.keyDown, 0), .key(.keyUp, 0)])
    }

    func testCapacityIncludesInFlightInputAndOverflowClosesOwnerExactlyOnce() async throws {
        let probe = SendProbe(blockSendNumber: 1)
        var failures: [RemoteControlViewerInputFailure] = []
        let dispatcher = RemoteControlViewerInputDispatcher(
            capacity: 2,
            send: { try await probe.send($0) },
            onFailure: { failures.append($0) }
        )
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        await probe.waitForBlockedSend()
        try dispatcher.submitKeyboard(key(.keyUp, 0))

        XCTAssertThrowsError(try dispatcher.submitMouse(mouse(.leftMouseDown, 0))) { error in
            guard case RemoteControlViewerInputFailure.capacityExceeded(limit: 2) = error else {
                return XCTFail("Expected explicit capacity failure, got \(error)")
            }
        }
        XCTAssertEqual(failures.count, 1, "Owner must terminate the connection and release uncertain input")
        XCTAssertThrowsError(try dispatcher.submitKeyboard(key(.keyUp, 0)))
        XCTAssertThrowsError(try dispatcher.activate())
        dispatcher.close()
        probe.resumeBlockedSend()
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(probe.sent, [.key(.keyDown, 0)])
    }

    func testConsecutiveMovementCanCoalesceAtCapacityWithoutDroppingRelease() async throws {
        let probe = SendProbe(blockSendNumber: 1)
        let dispatcher = makeDispatcher(probe, capacity: 3)
        try dispatcher.activate()
        try dispatcher.submitMouse(mouse(.leftMouseDown, 0))
        await probe.waitForBlockedSend()
        try dispatcher.submitKeyboard(key(.keyUp, 0))
        try dispatcher.submitMouse(mouse(.mouseMoved, 1))
        for position in 2...100 {
            try dispatcher.submitMouse(mouse(.mouseMoved, Double(position)))
        }
        probe.resumeBlockedSend()
        try await dispatcher.deactivate()

        XCTAssertEqual(probe.sent, [
            .mouse(.leftMouseDown, 0, 0), .key(.keyUp, 0),
            .mouse(.mouseMoved, 100, 100), .mouse(.leftMouseUp, 100, 100)
        ])
    }

    func testCloseCompletesPendingDeactivationBeforeTheTransportResumes() async throws {
        let probe = SendProbe(blockSendNumber: 2)
        let dispatcher = makeDispatcher(probe)
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        let deactivation = Task { try await dispatcher.deactivate() }
        await probe.waitForBlockedSend()
        dispatcher.close()

        do {
            try await deactivation.value
            XCTFail("Closing must fail the pending focus release")
        } catch RemoteControlViewerInputFailure.closed {
            // Completion is independent of a transport that ignores cancellation.
        }
        XCTAssertTrue(probe.hasBlockedSend)
        probe.resumeBlockedSend()
        XCTAssertThrowsError(try dispatcher.activate())
    }

    func testUnresponsiveSendTimesOutAndUnblocksDeactivationWithoutWaitingForTransport() async throws {
        let probe = SendProbe(blockSendNumber: 1)
        var failures: [RemoteControlViewerInputFailure] = []
        let dispatcher = RemoteControlViewerInputDispatcher(
            sendTimeout: .milliseconds(25),
            send: { try await probe.send($0) },
            onFailure: { failures.append($0) }
        )
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        await probe.waitForBlockedSend()

        do {
            try await dispatcher.deactivate()
            XCTFail("A nonresponsive sender must not block focus changes forever")
        } catch RemoteControlViewerInputFailure.sendTimedOut {
            // The owner closes its exact transport after uncertain delivery.
        }
        XCTAssertTrue(probe.hasBlockedSend, "Timeout must complete without joining an uncooperative sender")
        XCTAssertEqual(failures.count, 1)
        XCTAssertThrowsError(try dispatcher.activate())
        probe.resumeBlockedSend()
        XCTAssertEqual(probe.sent, [.key(.keyDown, 0)])
    }

    func testUnresponsiveSyntheticReleaseTimesOutAndFailsClosed() async throws {
        let probe = SendProbe(blockSendNumber: 2)
        var failures: [RemoteControlViewerInputFailure] = []
        let dispatcher = RemoteControlViewerInputDispatcher(
            sendTimeout: .milliseconds(25),
            send: { try await probe.send($0) },
            onFailure: { failures.append($0) }
        )
        try dispatcher.activate()
        try dispatcher.submitMouse(mouse(.leftMouseDown, 4))
        let release = Task { try await dispatcher.deactivate() }
        await probe.waitForBlockedSend()

        do {
            try await release.value
            XCTFail("A stalled release must fail the focus transition")
        } catch RemoteControlViewerInputFailure.releaseTimedOut {
            // The complete release sequence has one deadline, including synthetic Up.
        }
        XCTAssertTrue(probe.hasBlockedSend)
        XCTAssertEqual(failures.count, 1)
        probe.resumeBlockedSend()
        XCTAssertEqual(probe.sent, [.mouse(.leftMouseDown, 4, 4), .mouse(.leftMouseUp, 4, 4)])
    }

    func testSlowSuccessfulSendsCannotExtendTheTotalDeactivationDeadline() async throws {
        var sendCount = 0
        var failures: [RemoteControlViewerInputFailure] = []
        let dispatcher = RemoteControlViewerInputDispatcher(
            sendTimeout: .milliseconds(200),
            send: { _ in
                sendCount += 1
                try await Task.sleep(for: .milliseconds(20))
            },
            onFailure: { failures.append($0) }
        )
        try dispatcher.activate()
        for code in 0..<30 {
            try dispatcher.submitKeyboard(key(.keyDown, code))
        }

        do {
            try await dispatcher.deactivate()
            XCTFail("Successful individual sends must not extend the total release deadline")
        } catch RemoteControlViewerInputFailure.releaseTimedOut {
            // Each send takes 20 ms, below the 200 ms per-send timeout.
        }
        XCTAssertGreaterThan(sendCount, 1)
        XCTAssertLessThan(sendCount, 30)
        XCTAssertEqual(failures.count, 1)
        XCTAssertThrowsError(try dispatcher.activate())
    }

    func testSendFailurePreservesUnderlyingErrorAndStopsQueuedInput() async throws {
        let probe = SendProbe(failSendNumber: 1)
        var failures: [RemoteControlViewerInputFailure] = []
        let dispatcher = RemoteControlViewerInputDispatcher(
            send: { try await probe.send($0) },
            onFailure: { failures.append($0) }
        )
        try dispatcher.activate()
        try dispatcher.submitKeyboard(key(.keyDown, 0))
        try dispatcher.submitKeyboard(key(.keyUp, 0))

        do {
            try await dispatcher.deactivate()
            XCTFail("A transport failure must fail the focus transition")
        } catch RemoteControlViewerInputFailure.sendFailed(let underlying) {
            XCTAssertTrue(underlying is SendProbe.Failure)
        }
        XCTAssertEqual(probe.sent, [.key(.keyDown, 0)])
        XCTAssertEqual(failures.count, 1)
    }

    func testFailedSyntheticReleaseFailsClosedInsteadOfAllowingReactivation() async throws {
        let probe = SendProbe(failSendNumber: 2)
        var failures: [RemoteControlViewerInputFailure] = []
        let dispatcher = RemoteControlViewerInputDispatcher(
            send: { try await probe.send($0) },
            onFailure: { failures.append($0) }
        )
        try dispatcher.activate()
        try dispatcher.submitMouse(mouse(.leftMouseDown, 4))

        do {
            try await dispatcher.deactivate()
            XCTFail("A failed synthetic release must remain observable")
        } catch RemoteControlViewerInputFailure.sendFailed(let underlying) {
            XCTAssertTrue(underlying is SendProbe.Failure)
        }
        XCTAssertThrowsError(try dispatcher.activate())
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(probe.sent, [.mouse(.leftMouseDown, 4, 4), .mouse(.leftMouseUp, 4, 4)])
    }

    func testRetiredSenderFailureCannotCloseAReplacementDispatcher() async throws {
        let oldProbe = SendProbe(blockSendNumber: 1)
        var oldFailures: [RemoteControlViewerInputFailure] = []
        let old = RemoteControlViewerInputDispatcher(
            send: { try await oldProbe.send($0) },
            onFailure: { oldFailures.append($0) }
        )
        try old.activate()
        try old.submitKeyboard(key(.keyDown, 0))
        await oldProbe.waitForBlockedSend()
        old.close()

        let replacementProbe = SendProbe()
        let replacement = makeDispatcher(replacementProbe)
        try replacement.activate()
        try replacement.submitKeyboard(key(.keyDown, 1))
        oldProbe.resumeBlockedSend(throwing: SendProbe.Failure.transport)
        try await replacement.deactivate()

        XCTAssertTrue(oldFailures.isEmpty, "Late failure belongs to an already retired engine")
        XCTAssertEqual(replacementProbe.sent, [.key(.keyDown, 1), .key(.keyUp, 1)])
        XCTAssertThrowsError(try old.activate())
    }

    func testHeldInputStateHasAHardCapacityIndependentOfQueueDraining() async throws {
        let probe = SendProbe()
        var failures: [RemoteControlViewerInputFailure] = []
        let dispatcher = RemoteControlViewerInputDispatcher(
            capacity: 512,
            send: { try await probe.send($0) },
            onFailure: { failures.append($0) }
        )
        try dispatcher.activate()
        for code in 0...256 {
            try dispatcher.submitKeyboard(key(.keyDown, code))
        }
        do {
            try await dispatcher.deactivate()
            XCTFail("Distinct held keys must not grow without a bound")
        } catch RemoteControlViewerInputFailure.pressedControlCapacityExceeded(limit: 256) {
            // Closing the exact transport releases all keys already accepted remotely.
        }
        XCTAssertEqual(probe.sent.count, 256)
        XCTAssertEqual(failures.count, 1)
    }

    private func makeDispatcher(_ probe: SendProbe, capacity: Int = 256) -> RemoteControlViewerInputDispatcher {
        RemoteControlViewerInputDispatcher(
            capacity: capacity,
            send: { try await probe.send($0) },
            onFailure: { XCTFail("Unexpected terminal input failure: \($0)") }
        )
    }

    private func key(_ type: KeyboardEventType, _ code: Int) -> RemoteKeyboardEvent {
        RemoteKeyboardEvent(type: type, keyCode: code, timestamp: 1)
    }

    private func mouse(_ type: MouseEventType, _ position: Double) -> RemoteMouseEvent {
        RemoteMouseEvent(type: type, x: position, y: position, timestamp: 1)
    }
}

@MainActor
private final class SendProbe {
    enum Failure: Error { case transport }

    enum Record: Equatable {
        case key(KeyboardEventType, Int)
        case mouse(MouseEventType, Double, Double)
    }

    private let blockSendNumber: Int?
    private let failSendNumber: Int?
    private let blocked: AsyncStream<Void>
    private let blockedContinuation: AsyncStream<Void>.Continuation
    private var sendContinuation: CheckedContinuation<Void, any Error>?
    private(set) var sent: [Record] = []

    var hasBlockedSend: Bool { sendContinuation != nil }

    init(blockSendNumber: Int? = nil, failSendNumber: Int? = nil) {
        self.blockSendNumber = blockSendNumber
        self.failSendNumber = failSendNumber
        (blocked, blockedContinuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    func send(_ event: RemoteControlViewerInputEvent) async throws {
        switch event {
        case .keyboard(let key): sent.append(.key(key.type, key.keyCode))
        case .mouse(let mouse): sent.append(.mouse(mouse.type, mouse.x, mouse.y))
        }
        let sendNumber = sent.count
        if sendNumber == blockSendNumber {
            try await withCheckedThrowingContinuation { continuation in
                sendContinuation = continuation
                blockedContinuation.yield(())
            }
        }
        if sendNumber == failSendNumber { throw Failure.transport }
    }

    func waitForBlockedSend() async {
        for await _ in blocked { return }
        XCTFail("Input sender ended before reaching its suspension point")
    }

    func resumeBlockedSend(throwing error: (any Error)? = nil) {
        guard let continuation = sendContinuation else {
            return XCTFail("No input send is suspended")
        }
        sendContinuation = nil
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}
#endif
