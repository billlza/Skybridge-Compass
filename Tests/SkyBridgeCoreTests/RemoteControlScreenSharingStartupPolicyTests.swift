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

    func testAttemptGateSuppressesDuplicateStartWhileCurrentStartIsInFlight() {
        var gate = RemoteControlScreenSharingAttemptGate()

        let firstAttempt = gate.beginAttemptIfIdle(for: "peer-1")
        XCTAssertNotNil(firstAttempt)
        XCTAssertNil(gate.beginAttemptIfIdle(for: "peer-1"))

        if let firstAttempt {
            gate.finishAttempt(firstAttempt, for: "peer-1")
        }

        let secondAttempt = gate.beginAttemptIfIdle(for: "peer-1")
        XCTAssertNotNil(secondAttempt)
        XCTAssertNotEqual(firstAttempt, secondAttempt)
    }

    func testAttemptGateAllowsFreshStartAfterInvalidatingInFlightStart() {
        var gate = RemoteControlScreenSharingAttemptGate()

        let firstAttempt = gate.beginAttemptIfIdle(for: "peer-1")
        XCTAssertNotNil(firstAttempt)

        gate.invalidateAttempts(for: "peer-1")

        let secondAttempt = gate.beginAttemptIfIdle(for: "peer-1")
        XCTAssertNotNil(secondAttempt)
        XCTAssertNotEqual(firstAttempt, secondAttempt)
    }
}
