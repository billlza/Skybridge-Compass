#if os(macOS)
import Foundation
import XCTest
@testable import SkyBridgeCore

final class AudioBluetoothReceiveTraceTests: XCTestCase {
    func testTraceRetainsOnlyNewestBoundedEventsInChronologicalOrder() {
        let now = ContinuousClock.now
        var trace = AudioBluetoothReceiveTrace(now: now)
        for index in 0..<1_100 {
            trace.record(.received, value: UInt64(index), now: now.advanced(by: .milliseconds(index)))
        }
        XCTAssertEqual(trace.events.count, AudioBluetoothReceiveTrace.capacity)
        XCTAssertEqual(trace.events.map(\.value), Array(588..<1_100).map(UInt64.init))
        XCTAssertEqual(trace.events.first?.elapsed, .milliseconds(588))
        XCTAssertEqual(trace.events.last?.elapsed, .milliseconds(1_099))
    }

    func testOutputAndCreditObservationsPreserveCountsAndMonotonicTiming() {
        let now = ContinuousClock.now
        var trace = AudioBluetoothReceiveTrace(now: now)
        trace.record(.output, value: 9_288, auxiliary: 8_328, queued: 1, now: now.advanced(by: .milliseconds(40)))
        trace.record(.creditWriteEnd, value: 2_880, now: now.advanced(by: .milliseconds(42)))
        XCTAssertEqual(trace.events.map(\.diagnostic), [
            "ms=40.0 kind=output value=9288 auxiliary=8328 queued=1",
            "ms=42.0 kind=creditWriteEnd value=2880 auxiliary=0 queued=0"
        ])
    }
}
#endif
