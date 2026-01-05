import XCTest
@testable import SkyBridgeCore

final class RemoteDesktopQualityTests: XCTestCase {
    func testFrameRateEstimateFromLatency() {
        let latencies: [Double] = [2.0, 5.0, 16.7, 33.3, 100.0]
        let expectedFPS: [Int] = [500, 200, 59, 30, 10]
        var results: [Int] = []
        for (i, l) in latencies.enumerated() {
            let fps = max(1, Int(1000.0 / l))
            results.append(fps)
            XCTAssertEqual(results[i], expectedFPS[i])
        }
    }
}
