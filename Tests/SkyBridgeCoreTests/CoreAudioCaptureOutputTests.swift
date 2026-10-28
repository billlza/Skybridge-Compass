#if os(macOS)
import Foundation
import XCTest
@testable import SkyBridgeCore

/// Snapshot classification only: no HAL calls, device configuration, or playback.
final class CoreAudioCaptureOutputTests: XCTestCase {
    func testHistoricalCloseErrorDoesNotTurnReleasedResourcesIntoPendingOwnership() {
        let snapshot = snapshot(state: .closed, diagnostics: ["snapshot before stop: unavailable"])
        let result = CoreAudioCaptureOutput.cleanupOutcome(snapshot: snapshot,
            closeError: CoreAudioExactPcmOutputError.cleanupDiagnostics)
        XCTAssertEqual(result.state, .released)
        XCTAssertTrue(result.diagnostics.contains("snapshot before stop: unavailable"))
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    func testEveryUnclosedNativeStateRemainsPendingRegardlessOfDiagnosticText() {
        let states: [CoreAudioExactPcmOutputSnapshot.State] = [.idle, .preparing, .prepared, .running, .draining, .closing, .cleanupRequired]
        for state in states {
            let result = CoreAudioCaptureOutput.cleanupOutcome(snapshot: snapshot(state: state), closeError: nil)
            XCTAssertEqual(result.state, .pending, "\(state)")
        }
        let result = CoreAudioCaptureOutput.cleanupOutcome(snapshot: snapshot(state: .cleanupRequired,
            diagnostics: ["stop_delivery: deliberately misleading fixture"]), closeError: nil)
        XCTAssertEqual(result.state, .pending, "Diagnostic prefixes never decide resource ownership")
    }

    func testPreservedThirdPartyPropertiesAreReleasedButNeverReportedAsRestored() {
        let result = CoreAudioCaptureOutput.cleanupOutcome(snapshot: snapshot(state: .closed, preserved: ["nominalRate", "virtualFormat"]),
            closeError: CoreAudioExactPcmOutputError.restorationSkipped)
        XCTAssertEqual(result.state, .released)
        XCTAssertEqual(result.preservedExternalChanges, ["nominalRate", "virtualFormat"])
        XCTAssertFalse(result.diagnostics.isEmpty)
    }

    private func snapshot(state: CoreAudioExactPcmOutputSnapshot.State, diagnostics: [String] = [],
                          preserved: [String] = []) -> CoreAudioExactPcmOutputSnapshot {
        .init(ownerID: UUID(), state: state, acceptedFrames: 1, submittedFrames: 0, queuedFrames: 0,
              finalCountersVerified: false, failure: "failed stream remains failed", cleanupFailures: diagnostics,
              skippedRestorations: preserved, drainStatus: .failed, expectedSourceFrames: nil, trailingPaddingFrames: 0)
    }
}
#endif
