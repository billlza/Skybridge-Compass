import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCompass_iOS

@available(iOS 17.0, *)
@MainActor
final class RemoteDesktopInputDispatcherTests: XCTestCase {
    func testOrderedPressAndFocusReleaseKeepOriginalLease() async throws {
        let context = try inputContext()
        var sent: [RemoteMessage] = []
        let dispatcher = RemoteDesktopInputDispatcher(cancelPendingSend: { _ in XCTFail("Unexpected timeout") }, send: { message, captured in
            XCTAssertEqual(captured, context)
            sent.append(message)
        }, failed: { error, _ in XCTFail("Unexpected send failure: \(error)") })
        dispatcher.enqueue(.mouse(MouseEvent(type: .leftMouseDown, x: 40, y: 50)), context: context)
        dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: 12)), context: context)
        try await dispatcher.releasePressedInput()
        XCTAssertEqual(sent.map(\.type), [.mouseEvent, .keyboardEvent, .mouseEvent, .keyboardEvent])
        XCTAssertTrue(sent.allSatisfy { $0.inputControlLease == context.access?.lease })
        XCTAssertEqual(try JSONDecoder().decode(MouseEvent.self, from: sent[2].payload).type, .leftMouseUp)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardEvent.self, from: sent[3].payload).type, .keyUp)
        try await dispatcher.releasePressedInput()
        XCTAssertEqual(sent.count, 4, "Releasing an already released key must not duplicate native effects")
    }

    func testRevokedOwnerDiscardsQueuedInputAndNeverReleasesIntoReplacement() async throws {
        let context = try inputContext()
        var sent: [RemoteMessage] = []
        let dispatcher = RemoteDesktopInputDispatcher(cancelPendingSend: { _ in XCTFail("Unexpected timeout") }, send: { message, _ in sent.append(message) },
                                                    failed: { error, _ in XCTFail("\(error)") })
        dispatcher.enqueue(.mouse(MouseEvent(type: .leftMouseDown, x: 1, y: 1)), context: context)
        await dispatcher.drain()
        dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: 1)), context: context)
        dispatcher.retire()
        await dispatcher.drain()
        try await dispatcher.releasePressedInput()
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.inputControlLease, context.access?.lease)
    }

    func testConsecutivePointerMotionCoalescesWithoutCrossingButtonBoundary() async throws {
        let context = try inputContext()
        var xCoordinates: [Double] = []
        let dispatcher = RemoteDesktopInputDispatcher(cancelPendingSend: { _ in XCTFail("Unexpected timeout") }, send: { message, _ in
            xCoordinates.append(try JSONDecoder().decode(MouseEvent.self, from: message.payload).x)
        }, failed: { error, _ in XCTFail("\(error)") })
        dispatcher.enqueue(.mouse(MouseEvent(type: .mouseMoved, x: 1, y: 1)), context: context)
        dispatcher.enqueue(.mouse(MouseEvent(type: .mouseMoved, x: 2, y: 1)), context: context)
        dispatcher.enqueue(.mouse(MouseEvent(type: .leftMouseDown, x: 3, y: 1)), context: context)
        dispatcher.enqueue(.mouse(MouseEvent(type: .mouseMoved, x: 4, y: 1)), context: context)
        dispatcher.enqueue(.mouse(MouseEvent(type: .mouseMoved, x: 5, y: 1)), context: context)
        await dispatcher.drain()
        XCTAssertEqual(xCoordinates, [2, 3, 5])
    }

    func testLegacyInputOmitsLeaseAndManagedEnvelopeRoundTripsIt() throws {
        let event = RemoteDesktopInputDispatcher.Event.mouse(MouseEvent(type: .leftMouseDown, x: 1, y: 1))
        let managed = try inputContext()
        let message = try event.message(context: managed)
        let decoded = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.inputControlLease, managed.access?.lease)
        let legacy = RemoteDesktopInputContext(connectionID: "legacy", streamEpoch: 1,
                                               transaction: RemoteDesktopStreamConfigurationTransaction(), access: nil)
        XCTAssertNil(try event.message(context: legacy).inputControlLease)
    }

    func testQueueOverflowFailsExplicitlyBeforeAnyQueuedNativeEffect() async throws {
        let context = try inputContext()
        let failed = Signal()
        var sent = 0
        var observed: RemoteDesktopInputDispatcher.Failure?
        let dispatcher = RemoteDesktopInputDispatcher(capacity: 2, cancelPendingSend: { _ in XCTFail("Unexpected timeout") }, send: { _, _ in sent += 1 },
                                                    failed: { error, _ in
            observed = error as? RemoteDesktopInputDispatcher.Failure
            failed.signal()
        })
        for code in 1...3 {
            dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: code)), context: context)
        }
        await failed.wait()
        await dispatcher.drain()
        XCTAssertEqual(observed, .queueCapacityExceeded)
        XCTAssertEqual(sent, 0)
    }

    func testConfigurationWaitRequiresPeerAcknowledgementAndExposesTimeout() async throws {
        let waiter = RemoteDesktopConfigurationWaiter()
        let transaction = RemoteDesktopStreamConfigurationTransaction()
        let acknowledgement = Task { waiter.acknowledge(transaction) }
        try await waiter.wait(for: transaction)
        await acknowledgement.value

        do {
            try await waiter.wait(for: RemoteDesktopStreamConfigurationTransaction(), timeout: .milliseconds(1))
            XCTFail("A pause without a peer ACK must fail")
        } catch {
            guard case RemoteDesktopError.timeout = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testHostAccessMessageIsDistinctFromStreamTransactionReceipt() throws {
        let access = try RemoteControlAccess(revision: 2, role: .observer, lease: nil)
        let message = RemoteMessage(type: .controlAccess, payload: try JSONEncoder().encode(access))
        let decoded = try JSONDecoder().decode(RemoteMessage.self, from: JSONEncoder().encode(message))
        XCTAssertEqual(decoded.type, .controlAccess)
        XCTAssertEqual(try JSONDecoder().decode(RemoteControlAccess.self, from: decoded.payload), access)
        XCTAssertNil(decoded.inputControlLease)
    }

    func testConfigurationReplacementReleasesShiftAndDragUsingPreviousContext() async throws {
        let first = try inputContext()
        var current = first
        var committed: [RemoteMessage] = []
        let dispatcher = RemoteDesktopInputDispatcher(cancelPendingSend: { _ in XCTFail("Unexpected timeout") },
                                                    send: { message, owner in
            guard owner == current else { throw CancellationError() }
            committed.append(message)
        }, failed: { error, _ in XCTFail("\(error)") })
        dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: 56)), context: first)
        dispatcher.enqueue(.mouse(MouseEvent(type: .leftMouseDown, x: 10, y: 20)), context: first)
        await dispatcher.drain()
        // This is the barrier used by the manager before retiring the old stream transaction.
        try await dispatcher.releasePressedInput()
        current = RemoteDesktopInputContext(connectionID: first.connectionID, streamEpoch: first.streamEpoch,
                                            transaction: RemoteDesktopStreamConfigurationTransaction(), access: first.access)
        dispatcher.enqueue(.mouse(MouseEvent(type: .mouseMoved, x: 15, y: 25)), context: current)
        await dispatcher.drain()
        XCTAssertEqual(committed.map(\.type), [.keyboardEvent, .mouseEvent, .mouseEvent, .keyboardEvent, .mouseEvent])
        XCTAssertEqual(try JSONDecoder().decode(MouseEvent.self, from: committed[2].payload).type, .leftMouseUp)
        XCTAssertEqual(try JSONDecoder().decode(KeyboardEvent.self, from: committed[3].payload).type, .keyUp)
        XCTAssertTrue(committed.allSatisfy { $0.inputControlLease == first.access?.lease })
    }

    func testConcurrentReleaseCallersWaitForTheSameCommittedRelease() async throws {
        let context = try inputContext()
        let releaseEntered = Signal()
        let allowRelease = Signal()
        var keyUps = 0
        let dispatcher = RemoteDesktopInputDispatcher(cancelPendingSend: { _ in XCTFail("Unexpected timeout") },
                                                    send: { message, _ in
            let key = try JSONDecoder().decode(KeyboardEvent.self, from: message.payload)
            if key.type == .keyUp {
                keyUps += 1
                releaseEntered.signal()
                await allowRelease.wait()
            }
        }, failed: { error, _ in XCTFail("\(error)") })
        dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: 56)), context: context)
        await dispatcher.drain()
        let first = Task { try await dispatcher.releasePressedInput() }
        await releaseEntered.wait()
        let secondEntered = Signal()
        var secondReturned = false
        let second = Task {
            secondEntered.signal()
            try await dispatcher.releasePressedInput()
            secondReturned = true
        }
        await secondEntered.wait()
        XCTAssertFalse(secondReturned)
        allowRelease.signal()
        try await first.value
        try await second.value
        XCTAssertEqual(keyUps, 1)
    }

    func testConfigurationAdmissionStaysClosedBetweenSharedReleaseCompletionAndCommit() async throws {
        let first = try inputContext()
        var current = first
        var committed: [KeyboardEventType] = []
        let releaseEntered = Signal()
        let allowRelease = Signal()
        let releaseCompleted = Signal()
        let allowConfigurationCommit = Signal()
        let dispatcher = RemoteDesktopInputDispatcher(cancelPendingSend: { _ in XCTFail("Unexpected timeout") },
                                                    send: { message, context in
            guard context == current else { throw CancellationError() }
            let key = try JSONDecoder().decode(KeyboardEvent.self, from: message.payload)
            if key.type == .keyUp {
                releaseEntered.signal()
                await allowRelease.wait()
            }
            committed.append(key.type)
        }, failed: { error, _ in XCTFail("\(error)") })
        dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: 56)), context: first)
        await dispatcher.drain()
        let configuration = Task {
            let token = dispatcher.beginConfigurationUpdate()
            defer { dispatcher.finishConfigurationUpdate(token) }
            try await dispatcher.releasePressedInput()
            releaseCompleted.signal()
            await allowConfigurationCommit.wait()
            current = RemoteDesktopInputContext(connectionID: first.connectionID, streamEpoch: first.streamEpoch,
                                                transaction: RemoteDesktopStreamConfigurationTransaction(), access: first.access)
        }
        await releaseEntered.wait()
        let otherWaiter = Task {
            try await dispatcher.releasePressedInput()
            // The manager's old ACK is deliberately still current here.
            dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: 12)), context: first)
            await dispatcher.drain()
        }
        allowRelease.signal()
        await releaseCompleted.wait()
        try await otherWaiter.value
        XCTAssertEqual(committed, [.keyDown, .keyUp], "A completed release cannot reopen its configuration owner's admission")
        allowConfigurationCommit.signal()
        try await configuration.value
        dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: 12)), context: current)
        await dispatcher.drain()
        XCTAssertEqual(committed, [.keyDown, .keyUp, .keyDown])
    }

    func testOneConfigurationCannotReleaseAnotherConfigurationsAdmission() async throws {
        let context = try inputContext()
        var committed = 0
        let dispatcher = RemoteDesktopInputDispatcher(cancelPendingSend: { _ in XCTFail("Unexpected timeout") },
                                                    send: { _, _ in committed += 1 },
                                                    failed: { error, _ in XCTFail("\(error)") })
        let first = dispatcher.beginConfigurationUpdate()
        let second = dispatcher.beginConfigurationUpdate()
        dispatcher.finishConfigurationUpdate(first)
        dispatcher.finishConfigurationUpdate(first)
        dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: 12)), context: context)
        await dispatcher.drain()
        XCTAssertEqual(committed, 0)
        dispatcher.finishConfigurationUpdate(second)
        dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: 12)), context: context)
        await dispatcher.drain()
        XCTAssertEqual(committed, 1)
    }

    func testTotalReleaseDeadlineCancelsAnUnfinishedWriteAndUnblocksFocus() async throws {
        let context = try inputContext()
        let writeEntered = Signal()
        let unblockWrite = Signal()
        var cancelledOwners: [RemoteDesktopInputContext] = []
        let dispatcher = RemoteDesktopInputDispatcher(releaseTimeout: .milliseconds(10),
                                                    cancelPendingSend: { owner in
            cancelledOwners.append(owner)
            unblockWrite.signal()
        }, send: { _, _ in
            writeEntered.signal()
            await unblockWrite.wait()
        }, failed: { error, _ in XCTFail("\(error)") })
        dispatcher.enqueue(.keyboard(KeyboardEvent(type: .keyDown, keyCode: 56)), context: context)
        await writeEntered.wait()
        do {
            try await dispatcher.releasePressedInput()
            XCTFail("An uncommitted write must not hold focus indefinitely")
        } catch {
            XCTAssertEqual(error as? RemoteDesktopOperationDeadline.Failure, .expired(.inputRelease))
        }
        await dispatcher.drain()
        XCTAssertEqual(cancelledOwners, [context])
    }

    func testWriteDeadlineCancelsCapturedResourceAndIgnoresLateCallback() async throws {
        let original = CancellationCounter()
        let replacement = CancellationCounter()
        var originalCallback: (@Sendable (Result<Void, any Error>) -> Void)?
        let deadline = RemoteDesktopOperationDeadline(cancelResource: { original.count += 1 })
        do {
            try await deadline.run(timeout: .milliseconds(1), phase: .lanWrite) { originalCallback = $0 }
            XCTFail("A writer without a completion must time out")
        } catch {
            XCTAssertEqual(error as? RemoteDesktopOperationDeadline.Failure, .expired(.lanWrite))
        }
        let replacementStarted = Signal()
        var replacementCallback: (@Sendable (Result<Void, any Error>) -> Void)?
        var replacementCompleted = false
        let replacementOperation = Task {
            let operation = RemoteDesktopOperationDeadline(cancelResource: { replacement.count += 1 })
            try await operation.run(timeout: .seconds(1), phase: .lanWrite) {
                replacementCallback = $0
                replacementStarted.signal()
            }
            replacementCompleted = true
        }
        await replacementStarted.wait()
        originalCallback?(.success(()))
        originalCallback?(.failure(RemoteDesktopError.disconnected))
        await Task.yield()
        XCTAssertFalse(replacementCompleted)
        XCTAssertEqual(original.count, 1)
        XCTAssertEqual(replacement.count, 0)
        replacementCallback?(.success(()))
        try await replacementOperation.value
    }

    func testWriteCancellationClosesCapturedResourceBeforeLateCompletion() async throws {
        let started = Signal()
        let resource = CancellationCounter()
        var callback: (@Sendable (Result<Void, any Error>) -> Void)?
        let task = Task {
            let deadline = RemoteDesktopOperationDeadline(cancelResource: { resource.count += 1 })
            try await deadline.run(timeout: .seconds(1), phase: .lanWrite) {
                callback = $0
                started.signal()
            }
        }
        await started.wait()
        task.cancel()
        do {
            try await task.value
            XCTFail("Cancellation must remain a failure")
        } catch is CancellationError {
            XCTAssertTrue(task.isCancelled)
        }
        XCTAssertEqual(resource.count, 1)
        callback?(.success(()))
        await Task.yield()
        XCTAssertEqual(resource.count, 1)
    }

    private func inputContext() throws -> RemoteDesktopInputContext {
        RemoteDesktopInputContext(connectionID: "connection-one", streamEpoch: 1,
                                  transaction: RemoteDesktopStreamConfigurationTransaction(),
                                  access: try RemoteControlAccess(revision: 1, role: .controller, lease: UUID()))
    }

    @MainActor
    private final class CancellationCounter { var count = 0 }

    @MainActor
    private final class Signal {
        private var signalled = false
        private var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            if signalled { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func signal() { signalled = true; continuation?.resume(); continuation = nil }
    }
}
