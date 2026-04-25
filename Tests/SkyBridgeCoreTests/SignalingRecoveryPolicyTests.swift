import XCTest
@testable import SkyBridgeCore

@MainActor
final class SignalingRecoveryPolicyTests: XCTestCase {
    func testPostTransportIceCandidateFailuresDeferToSharedRecoveryTask() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                messageType: .iceCandidate
            )
        )
    }

    func testPreTransportOrNonIceFailuresAreNotSilentlyDeferred() {
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: false,
                messageType: .iceCandidate
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                messageType: .offer
            )
        )
    }

    func testOnlyHandshakeCompleteFailuresSwitchToOnDemandSignaling() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldUseOnDemandSignalingAfterTransportFailure(
                isHandshakeComplete: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldUseOnDemandSignalingAfterTransportFailure(
                isHandshakeComplete: false
            )
        )
    }
}
