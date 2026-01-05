import XCTest
@testable import SkyBridgeCore

final class WeakNetworkBackoffTests: XCTestCase {
    func testExponentialBackoffProgression() {
        let initial = 500
        let maxVal = 8000
        let multiplier = 2.0
        var delay = initial
        var seq: [Int] = []
        for _ in 0..<5 {
            seq.append(delay)
            delay = min(Int(Double(delay) * multiplier), maxVal)
        }
        XCTAssertEqual(seq, [500, 1000, 2000, 4000, 8000])
    }
}
