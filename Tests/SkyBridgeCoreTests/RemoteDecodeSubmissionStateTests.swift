import XCTest
@testable import SkyBridgeCore

final class RemoteDecodeSubmissionStateTests: XCTestCase {
    func testInFlightLimitIsBoundedAndCompletionReleasesCapacity() {
        var state = RemoteDecodeSubmissionState()
        XCTAssertTrue(state.begin(maximumInFlightCount: 2))
        XCTAssertTrue(state.begin(maximumInFlightCount: 2))
        XCTAssertFalse(state.begin(maximumInFlightCount: 2))
        XCTAssertEqual(state.inFlightCount, 2)

        state.complete(succeeded: true)
        XCTAssertEqual(state.inFlightCount, 1)
        XCTAssertTrue(state.begin(maximumInFlightCount: 2))
    }

    func testDecodeFailureRequiresNewSyncFrame() {
        var state = RemoteDecodeSubmissionState()
        state.clearWaitingForSyncFrame()
        XCTAssertTrue(state.begin(maximumInFlightCount: 3))
        state.complete(succeeded: false)
        XCTAssertTrue(state.isWaitingForSyncFrame)
        XCTAssertEqual(state.inFlightCount, 0)
    }

    func testFormatReplacementResetClearsGhostInFlightFrames() {
        var state = RemoteDecodeSubmissionState()
        state.clearWaitingForSyncFrame()
        XCTAssertTrue(state.begin(maximumInFlightCount: 3))
        XCTAssertTrue(state.begin(maximumInFlightCount: 3))

        state.reset(waitingForSyncFrame: true)
        XCTAssertEqual(state.inFlightCount, 0)
        XCTAssertTrue(state.isWaitingForSyncFrame)
        XCTAssertTrue(state.begin(maximumInFlightCount: 3))
    }
}
