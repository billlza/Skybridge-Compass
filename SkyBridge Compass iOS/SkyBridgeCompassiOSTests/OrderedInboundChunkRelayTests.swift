import XCTest
@testable import SkyBridgeCompass_iOS

final class OrderedInboundChunkRelayTests: XCTestCase {
    func testSubmitPreservesArrivalOrderAcrossSuspension() async {
        let relay = OrderedInboundChunkRelay()
        let recorder = RelayEventRecorder()

        XCTAssertTrue(relay.submit(byteCount: 1) {
            await recorder.record("first-start")
            try? await Task.sleep(for: .milliseconds(60))
            await recorder.record("first-end")
        })
        XCTAssertTrue(relay.submit(byteCount: 1) {
            await recorder.record("second")
        })
        XCTAssertTrue(relay.submit(byteCount: 1) {
            await recorder.record("third-start")
            try? await Task.sleep(for: .milliseconds(10))
            await recorder.record("third-end")
        })

        try? await Task.sleep(for: .milliseconds(200))
        relay.cancel()

        let events = await recorder.snapshot()
        XCTAssertEqual(
            events,
            ["first-start", "first-end", "second", "third-start", "third-end"]
        )
    }

    func testSubmitFailsClosedAfterCapacityViolationAndAfterCancel() async {
        let relay = OrderedInboundChunkRelay(maxPendingOperations: 1, maxPendingBytes: 4)
        let gate = RelaySuspensionGate()

        XCTAssertTrue(relay.submit(byteCount: 4) {
            await gate.wait()
        })
        XCTAssertFalse(relay.submit(byteCount: 1) {})
        XCTAssertFalse(relay.submit(byteCount: 1) {})

        await gate.release()
        relay.cancel()
        XCTAssertFalse(relay.submit(byteCount: 1) {})
    }

    func testCancelRequestsCancellationForRunningAndEveryQueuedTask() async throws {
        let relay = OrderedInboundChunkRelay(
            maxPendingOperations: 3,
            maxPendingBytes: 3
        )
        let recorder = RelayEventRecorder()
        defer { relay.cancel() }

        XCTAssertTrue(relay.submit(byteCount: 1) {
            await recorder.record("first-start")
            do {
                try await Task.sleep(for: .seconds(5))
                await recorder.record("first-finished")
            } catch is CancellationError {
                await recorder.record("first-cancelled")
            } catch {
                await recorder.record("first-unexpected-error")
            }
        })
        XCTAssertTrue(relay.submit(byteCount: 1) {
            await recorder.record("second-started")
        })
        XCTAssertTrue(relay.submit(byteCount: 1) {
            await recorder.record("third-started")
        })

        try await waitForRelayEvent("first-start", recorder: recorder)
        XCTAssertEqual(relay.ownedTaskCount, 3)

        relay.cancel()
        try await waitForRelayOwnedTaskCount(0, relay: relay)

        let events = await recorder.snapshot()
        XCTAssertEqual(events, ["first-start", "first-cancelled"])
        XCTAssertFalse(relay.submit(byteCount: 1) {})
    }
}

private actor RelayEventRecorder {
    private var events: [String] = []

    func record(_ value: String) {
        events.append(value)
    }

    func snapshot() -> [String] {
        events
    }
}

private actor RelaySuspensionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func release() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}

private enum RelayTestError: Error {
    case timedOut
}

private func waitForRelayEvent(
    _ expected: String,
    recorder: RelayEventRecorder
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while !(await recorder.snapshot().contains(expected)) {
        guard clock.now < deadline else {
            XCTFail("Timed out waiting for relay event \(expected)")
            throw RelayTestError.timedOut
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

private func waitForRelayOwnedTaskCount(
    _ expected: Int,
    relay: OrderedInboundChunkRelay
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while relay.ownedTaskCount != expected {
        guard clock.now < deadline else {
            XCTFail("Timed out waiting for relay owned-task count \(expected)")
            throw RelayTestError.timedOut
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
