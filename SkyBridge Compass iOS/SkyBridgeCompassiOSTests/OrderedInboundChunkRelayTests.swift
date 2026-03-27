import XCTest
@testable import SkyBridgeCompass_iOS

final class OrderedInboundChunkRelayTests: XCTestCase {
    func testSubmitPreservesArrivalOrderAcrossSuspension() async {
        let relay = OrderedInboundChunkRelay()
        let recorder = RelayEventRecorder()

        relay.submit {
            await recorder.record("first-start")
            try? await Task.sleep(for: .milliseconds(60))
            await recorder.record("first-end")
        }
        relay.submit {
            await recorder.record("second")
        }
        relay.submit {
            await recorder.record("third-start")
            try? await Task.sleep(for: .milliseconds(10))
            await recorder.record("third-end")
        }

        try? await Task.sleep(for: .milliseconds(200))
        relay.cancel()

        let events = await recorder.snapshot()
        XCTAssertEqual(
            events,
            ["first-start", "first-end", "second", "third-start", "third-end"]
        )
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
