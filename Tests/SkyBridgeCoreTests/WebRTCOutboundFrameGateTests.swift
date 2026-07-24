#if canImport(WebRTC)
import XCTest
@testable import SkyBridgeCore

final class WebRTCOutboundFrameGateTests: XCTestCase {
    func testQueuedCancellationRemovesWaiterWithoutRunningOrRetainingPayload() async throws {
        let gate = WebRTCOutboundFrameGate(maximumWaiters: 1)
        let holderStarted = FrameGateTestLatch()
        let releaseHolder = FrameGateTestLatch()
        let operationCount = FrameGateOperationCount()

        let holder = Task {
            try await gate.run {
                await holderStarted.open()
                await releaseHolder.wait()
            }
        }
        defer {
            holder.cancel()
            Task { await releaseHolder.open() }
        }
        await holderStarted.wait()

        weak var weakPayload: FrameGatePayload?
        var queued: Task<Void, Error>?
        do {
            let payload = FrameGatePayload()
            weakPayload = payload
            queued = Task {
                try await gate.run { [payload] in
                    _ = payload
                    await operationCount.increment()
                }
            }
        }

        try await waitForPendingWaiterCount(1, gate: gate)
        queued?.cancel()
        do {
            try await queued?.value
            XCTFail("A cancelled frame-gate waiter must throw CancellationError")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        queued = nil

        try await waitForPendingWaiterCount(0, gate: gate)
        for _ in 0..<20 where weakPayload != nil {
            await Task.yield()
        }
        let finalOperationCount = await operationCount.value
        XCTAssertNil(weakPayload)
        XCTAssertEqual(finalOperationCount, 0)

        await releaseHolder.open()
        try await holder.value
    }

    func testWaiterLimitFailsExplicitlyAndPreservesFIFOOwner() async throws {
        let gate = WebRTCOutboundFrameGate(maximumWaiters: 1)
        let holderStarted = FrameGateTestLatch()
        let releaseHolder = FrameGateTestLatch()
        let releaseQueued = FrameGateTestLatch()

        let holder = Task {
            try await gate.run {
                await holderStarted.open()
                await releaseHolder.wait()
            }
        }
        defer {
            holder.cancel()
            Task { await releaseHolder.open() }
        }
        await holderStarted.wait()

        let queued = Task {
            try await gate.run {
                await releaseQueued.wait()
            }
        }
        defer {
            queued.cancel()
            Task { await releaseQueued.open() }
        }
        try await waitForPendingWaiterCount(1, gate: gate)

        do {
            try await gate.run {}
            XCTFail("A full frame-gate queue must fail explicitly")
        } catch let error as WebRTCOutboundFrameGate.GateError {
            XCTAssertEqual(error, .waiterLimitExceeded(maximum: 1))
        } catch {
            XCTFail("Expected waiterLimitExceeded, got \(error)")
        }

        await releaseHolder.open()
        try await holder.value
        await releaseQueued.open()
        try await queued.value
        let finalWaiterCount = await gate.pendingWaiterCount
        XCTAssertEqual(finalWaiterCount, 0)
    }

    private func waitForPendingWaiterCount(
        _ expectedCount: Int,
        gate: WebRTCOutboundFrameGate
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while await gate.pendingWaiterCount != expectedCount {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for frame-gate waiter count \(expectedCount)")
                throw FrameGateTestError.timedOut
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor FrameGateTestLatch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private actor FrameGateOperationCount {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class FrameGatePayload: @unchecked Sendable {}

private enum FrameGateTestError: Error {
    case timedOut
}
#endif
