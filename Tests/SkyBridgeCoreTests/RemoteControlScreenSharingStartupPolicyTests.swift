import XCTest
@testable import SkyBridgeCore

final class RemoteControlScreenSharingStartupPolicyTests: XCTestCase {
    func testInitialDecisionStartsImmediatelyWhenViewerConfigurationExists() {
        let decision = RemoteControlScreenSharingStartupPolicy.decision(
            hasInitialStreamConfiguration: true
        )

        XCTAssertEqual(decision, .startImmediately)
    }

    func testInitialDecisionWaitsForViewerConfigurationBeforeLegacyFallback() {
        let decision = RemoteControlScreenSharingStartupPolicy.decision(
            hasInitialStreamConfiguration: false
        )

        XCTAssertEqual(
            decision,
            .awaitViewerConfiguration(
                fallbackAfter: RemoteControlScreenSharingStartupPolicy.legacyFallbackDelay
            )
        )
    }

    func testAttemptGateInvalidatesStaleScreenSharingStarts() {
        var gate = RemoteControlScreenSharingAttemptGate()

        let firstAttempt = gate.beginAttempt(for: "peer-1")
        let secondAttempt = gate.beginAttempt(for: "peer-1")

        XCTAssertFalse(gate.isCurrentAttempt(firstAttempt, for: "peer-1"))
        XCTAssertTrue(gate.isCurrentAttempt(secondAttempt, for: "peer-1"))

        gate.invalidateAttempts(for: "peer-1")

        XCTAssertFalse(gate.isCurrentAttempt(secondAttempt, for: "peer-1"))
    }
}
