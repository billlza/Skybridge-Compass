import XCTest
@testable import SkyBridgeCore

final class OrderedInboundChunkRelayTests: XCTestCase {
    func testSubmitPreservesArrivalOrderAcrossSuspension() async {
        let relay = CrossNetworkConnectionManager.OrderedInboundChunkRelay()
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

    func testSubmitFailsClosedWhenBacklogLimitIsExceeded() async {
        let relay = CrossNetworkConnectionManager.OrderedInboundChunkRelay(
            maxPendingOperations: 2,
            maxPendingBytes: 4
        )
        let gate = RelaySuspensionGate()

        XCTAssertTrue(relay.submit(byteCount: 2) {
            await gate.wait()
        })
        XCTAssertTrue(relay.submit(byteCount: 2) {})
        XCTAssertFalse(relay.submit(byteCount: 1) {})
        XCTAssertFalse(relay.submit(byteCount: 0) {})

        await gate.release()
        relay.cancel()
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
    private var released = false

    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
