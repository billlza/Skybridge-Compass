import Foundation
import XCTest
@testable import SkyBridgeCameraKit

final class ReceiveBrokerTests: XCTestCase {
    func testTimedOutWaitCachesLateBytesWithoutStartingASecondReceive() async throws {
        let timeoutScheduler = ManualReceiveTimeoutScheduler()
        let source = ControlledReceiveSource()
        let broker = RTSPPendingReceiveBroker(timeoutScheduler: timeoutScheduler.scheduler)
        let identity = ReceiveConnectionIdentity()
        let context = receiveContext(generation: 1, identity: identity)
        let start = receiveStart(source: source)

        let firstWait = Task {
            try await broker.receive(
                context: context,
                timeout: .seconds(30),
                stage: "first wait",
                start: start
            )
        }
        guard await waitForReceiveCallCount(1, source: source) else {
            firstWait.cancel()
            await broker.reset()
            return XCTFail("the first logical wait did not start its receive")
        }

        let firedFirstTimeout = await timeoutScheduler.fire(0)
        XCTAssertTrue(firedFirstTimeout)
        do {
            _ = try await firstWait.value
            XCTFail("the first logical wait must time out")
        } catch {
            XCTAssertEqual(error as? SkyBridgeCameraError, .timedOut("first wait"))
        }
        let callCountAfterTimeout = await source.callCount
        XCTAssertEqual(callCountAfterTimeout, 1)

        let bytes = Data([0x24, 0x00, 0x00, 0x02, 0x80, 0x60])
        let completedLateReceive = await source.complete(
            call: 0,
            with: .success(RTSPReceiveChunk(data: bytes, isComplete: false))
        )
        XCTAssertTrue(completedLateReceive)

        let secondChunk = try await broker.receive(
            context: context,
            timeout: .seconds(30),
            stage: "second wait",
            start: start
        )
        XCTAssertEqual(secondChunk, RTSPReceiveChunk(data: bytes, isComplete: false))
        let finalCallCount = await source.callCount
        XCTAssertEqual(finalCallCount, 1)
    }

    func testExpiredTimerCannotCancelReplacementWaiter() async throws {
        let timeoutScheduler = ManualReceiveTimeoutScheduler()
        let source = ControlledReceiveSource()
        let broker = RTSPPendingReceiveBroker(timeoutScheduler: timeoutScheduler.scheduler)
        let identity = ReceiveConnectionIdentity()
        let context = receiveContext(generation: 2, identity: identity)
        let start = receiveStart(source: source)

        let firstWait = Task {
            try await broker.receive(
                context: context,
                timeout: .seconds(30),
                stage: "expired waiter",
                start: start
            )
        }
        guard await waitForReceiveCallCount(1, source: source) else {
            firstWait.cancel()
            await broker.reset()
            return XCTFail("the first logical wait did not start its receive")
        }
        let firedFirstTimeout = await timeoutScheduler.fire(0)
        XCTAssertTrue(firedFirstTimeout)
        do {
            _ = try await firstWait.value
            XCTFail("the first logical wait must time out")
        } catch {
            XCTAssertEqual(error as? SkyBridgeCameraError, .timedOut("expired waiter"))
        }

        let replacementWait = Task {
            try await broker.receive(
                context: context,
                timeout: .seconds(30),
                stage: "replacement waiter",
                start: start
            )
        }
        guard await waitForScheduledTimeoutCount(2, scheduler: timeoutScheduler) else {
            replacementWait.cancel()
            await broker.reset()
            return XCTFail("the replacement waiter did not install its timer")
        }
        let callCountBeforeCompletion = await source.callCount
        XCTAssertEqual(callCountBeforeCompletion, 1)

        // Force the already-cancelled first timer to fire again. Its stale
        // waiter token must not affect the replacement waiter.
        let firedStaleTimeout = await timeoutScheduler.fire(
            0,
            includingCancelled: true
        )
        XCTAssertTrue(firedStaleTimeout)
        let bytes = Data([0x24, 0x01, 0x00, 0x01, 0xAA])
        let completedReceive = await source.complete(
            call: 0,
            with: .success(RTSPReceiveChunk(data: bytes, isComplete: false))
        )
        XCTAssertTrue(completedReceive)
        let replacementChunk = try await replacementWait.value
        XCTAssertEqual(replacementChunk.data, bytes)
    }

    func testConcurrentWaiterFailsFastWithoutStartingAnotherReceive() async throws {
        let timeoutScheduler = ManualReceiveTimeoutScheduler()
        let source = ControlledReceiveSource()
        let broker = RTSPPendingReceiveBroker(timeoutScheduler: timeoutScheduler.scheduler)
        let identity = ReceiveConnectionIdentity()
        let context = receiveContext(generation: 3, identity: identity)
        let start = receiveStart(source: source)

        let firstWait = Task {
            try await broker.receive(
                context: context,
                timeout: .seconds(30),
                stage: "primary waiter",
                start: start
            )
        }
        guard await waitForReceiveCallCount(1, source: source) else {
            firstWait.cancel()
            await broker.reset()
            return XCTFail("the primary waiter did not start its receive")
        }

        do {
            _ = try await broker.receive(
                context: context,
                timeout: .seconds(30),
                stage: "concurrent waiter",
                start: start
            )
            XCTFail("a second concurrent waiter must fail fast")
        } catch let error as SkyBridgeCameraError {
            guard case let .invalidState(reason) = error else {
                await broker.reset()
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertEqual(reason, "concurrent RTSP receive waiters are not supported")
        }
        let callCountBeforeCompletion = await source.callCount
        XCTAssertEqual(callCountBeforeCompletion, 1)

        let bytes = Data([0x01, 0x02, 0x03])
        let completedReceive = await source.complete(
            call: 0,
            with: .success(RTSPReceiveChunk(data: bytes, isComplete: false))
        )
        XCTAssertTrue(completedReceive)
        let firstChunk = try await firstWait.value
        XCTAssertEqual(firstChunk.data, bytes)
    }

    func testCancelledOldCallbackCannotCrossResetIntoNewConnection() async throws {
        let timeoutScheduler = ManualReceiveTimeoutScheduler()
        let source = ControlledReceiveSource()
        let broker = RTSPPendingReceiveBroker(timeoutScheduler: timeoutScheduler.scheduler)
        let firstIdentity = ReceiveConnectionIdentity()
        let secondIdentity = ReceiveConnectionIdentity()
        let firstContext = receiveContext(generation: 4, identity: firstIdentity)
        let secondContext = receiveContext(generation: 5, identity: secondIdentity)
        let start = receiveStart(source: source)

        let firstWait = Task {
            try await broker.receive(
                context: firstContext,
                timeout: .seconds(30),
                stage: "old connection",
                start: start
            )
        }
        guard await waitForReceiveCallCount(1, source: source) else {
            firstWait.cancel()
            await broker.reset()
            return XCTFail("the old connection did not start its receive")
        }
        firstWait.cancel()
        do {
            _ = try await firstWait.value
            XCTFail("cancelling the logical waiter must be observable")
        } catch {
            XCTAssertEqual(error as? SkyBridgeCameraError, .cancelled)
        }
        await broker.reset()

        let secondWait = Task {
            try await broker.receive(
                context: secondContext,
                timeout: .seconds(30),
                stage: "new connection",
                start: start
            )
        }
        guard await waitForReceiveCallCount(2, source: source) else {
            secondWait.cancel()
            await broker.reset()
            return XCTFail("the new connection did not start its receive")
        }

        let staleBytes = Data([0xDE, 0xAD])
        let completedStaleReceive = await source.complete(
            call: 0,
            with: .success(RTSPReceiveChunk(data: staleBytes, isComplete: false))
        )
        XCTAssertTrue(completedStaleReceive)
        let currentBytes = Data([0xBE, 0xEF])
        let completedCurrentReceive = await source.complete(
            call: 1,
            with: .success(RTSPReceiveChunk(data: currentBytes, isComplete: false))
        )
        XCTAssertTrue(completedCurrentReceive)
        let secondChunk = try await secondWait.value
        XCTAssertEqual(secondChunk.data, currentBytes)
    }

    func testLateOversizedResultIsNotBufferedAsData() async throws {
        let timeoutScheduler = ManualReceiveTimeoutScheduler()
        let source = ControlledReceiveSource()
        let broker = RTSPPendingReceiveBroker(timeoutScheduler: timeoutScheduler.scheduler)
        let identity = ReceiveConnectionIdentity()
        let context = receiveContext(generation: 6, identity: identity)
        let start = receiveStart(source: source)

        let firstWait = Task {
            try await broker.receive(
                context: context,
                timeout: .seconds(30),
                stage: "bounded wait",
                start: start
            )
        }
        guard await waitForReceiveCallCount(1, source: source) else {
            firstWait.cancel()
            await broker.reset()
            return XCTFail("the bounded wait did not start its receive")
        }
        let firedTimeout = await timeoutScheduler.fire(0)
        XCTAssertTrue(firedTimeout)
        do {
            _ = try await firstWait.value
            XCTFail("the first wait must time out")
        } catch {
            XCTAssertEqual(error as? SkyBridgeCameraError, .timedOut("bounded wait"))
        }

        let oversized = Data(repeating: 0xA5, count: 64 * 1_024 + 1)
        let completedOversizedReceive = await source.complete(
            call: 0,
            with: .success(RTSPReceiveChunk(data: oversized, isComplete: false))
        )
        XCTAssertTrue(completedOversizedReceive)
        do {
            _ = try await broker.receive(
                context: context,
                timeout: .seconds(30),
                stage: "consume bounded result",
                start: start
            )
            XCTFail("an oversized late receive must surface an explicit error")
        } catch {
            XCTAssertEqual(
                error as? SkyBridgeCameraError,
                .transportFailed(
                    "Network.framework returned more than 65536 bytes from one receive"
                )
            )
        }
        let finalCallCount = await source.callCount
        XCTAssertEqual(finalCallCount, 1)
    }

    private func receiveContext(
        generation: UInt64,
        identity: ReceiveConnectionIdentity
    ) -> RTSPReceiveContext {
        RTSPReceiveContext(
            connectionGeneration: generation,
            connectionIdentifier: ObjectIdentifier(identity)
        )
    }

    private func receiveStart(
        source: ControlledReceiveSource
    ) -> @Sendable (
        @escaping @Sendable (
            Result<RTSPReceiveChunk, SkyBridgeCameraError>
        ) async -> Void
    ) -> Void {
        { completion in
            Task { await source.record(completion) }
        }
    }

    private func waitForReceiveCallCount(
        _ expected: Int,
        source: ControlledReceiveSource
    ) async -> Bool {
        for _ in 0..<10_000 {
            if await source.callCount >= expected { return true }
            await Task.yield()
        }
        return await source.callCount >= expected
    }

    private func waitForScheduledTimeoutCount(
        _ expected: Int,
        scheduler: ManualReceiveTimeoutScheduler
    ) async -> Bool {
        for _ in 0..<10_000 {
            if scheduler.scheduledCount >= expected { return true }
            await Task.yield()
        }
        return scheduler.scheduledCount >= expected
    }
}

private final class ReceiveConnectionIdentity: Sendable {}

private actor ControlledReceiveSource {
    typealias Completion = @Sendable (
        Result<RTSPReceiveChunk, SkyBridgeCameraError>
    ) async -> Void

    private var completions: [Completion] = []

    var callCount: Int { completions.count }

    func record(_ completion: @escaping Completion) {
        completions.append(completion)
    }

    func complete(
        call: Int,
        with result: Result<RTSPReceiveChunk, SkyBridgeCameraError>
    ) async -> Bool {
        guard completions.indices.contains(call) else { return false }
        await completions[call](result)
        return true
    }
}

private final class ManualReceiveTimeoutScheduler: @unchecked Sendable {
    private struct Entry {
        let action: @Sendable (
            Result<Void, SkyBridgeCameraError>
        ) async -> Void
        var isCancelled: Bool
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    var scheduler: RTSPReceiveTimeoutScheduler {
        RTSPReceiveTimeoutScheduler { [self] _, action in
            let index = append(action)
            return RTSPReceiveTimeoutHandle { [self] in
                cancel(index)
            }
        }
    }

    var scheduledCount: Int {
        lock.withLock { entries.count }
    }

    func fire(_ index: Int, includingCancelled: Bool = false) async -> Bool {
        let action: (@Sendable (
            Result<Void, SkyBridgeCameraError>
        ) async -> Void)? = lock.withLock {
            guard entries.indices.contains(index),
                  includingCancelled || !entries[index].isCancelled
            else { return nil }
            return entries[index].action
        }
        guard let action else { return false }
        await action(.success(()))
        return true
    }

    private func append(
        _ action: @escaping @Sendable (
            Result<Void, SkyBridgeCameraError>
        ) async -> Void
    ) -> Int {
        lock.withLock {
            entries.append(Entry(action: action, isCancelled: false))
            return entries.index(before: entries.endIndex)
        }
    }

    private func cancel(_ index: Int) {
        lock.withLock {
            guard entries.indices.contains(index) else { return }
            entries[index].isCancelled = true
        }
    }
}
