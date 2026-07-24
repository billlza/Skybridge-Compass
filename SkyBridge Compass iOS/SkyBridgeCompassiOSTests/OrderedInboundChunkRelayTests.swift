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
