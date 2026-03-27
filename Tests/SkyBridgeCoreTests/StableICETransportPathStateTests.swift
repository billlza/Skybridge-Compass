import XCTest
@testable import SkyBridgeCore

final class StableICETransportPathStateTests: XCTestCase {
    @MainActor
    func testTransientUnknownProbeRetainsLastStablePath() {
        var state = StableICETransportPathState()

        XCTAssertFalse(state.recordProbe(.direct))
        XCTAssertEqual(state.effectivePath, .direct)

        XCTAssertTrue(state.recordProbe(.unknown, unknownProbeThreshold: 3))
        XCTAssertEqual(state.effectivePath, .direct)
        XCTAssertEqual(state.consecutiveUnknownProbes, 1)
    }

    @MainActor
    func testRepeatedUnknownProbesEventuallyDowngradeToUnknown() {
        var state = StableICETransportPathState()

        _ = state.recordProbe(.relay)
        XCTAssertEqual(state.effectivePath, .relay)

        XCTAssertTrue(state.recordProbe(.unknown, unknownProbeThreshold: 3))
        XCTAssertTrue(state.recordProbe(.unknown, unknownProbeThreshold: 3))
        XCTAssertFalse(state.recordProbe(.unknown, unknownProbeThreshold: 3))
        XCTAssertEqual(state.effectivePath, .unknown)
        XCTAssertEqual(state.consecutiveUnknownProbes, 3)
    }

    @MainActor
    func testStableDirectProbeResetsUnknownCounter() {
        var state = StableICETransportPathState()

        _ = state.recordProbe(.direct)
        _ = state.recordProbe(.unknown, unknownProbeThreshold: 3)
        XCTAssertEqual(state.consecutiveUnknownProbes, 1)

        XCTAssertFalse(state.recordProbe(.direct, unknownProbeThreshold: 3))
        XCTAssertEqual(state.effectivePath, .direct)
        XCTAssertEqual(state.consecutiveUnknownProbes, 0)
    }
}
