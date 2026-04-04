import XCTest
@testable import SkyBridgeCore

@MainActor
final class SignalingRecoveryPolicyTests: XCTestCase {
    func testPostTransportIceCandidateFailuresDeferToSharedRecoveryTask() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldDeferSignalingSendRecovery(
                isTransportEstablished: true,
                messageType: .iceCandidate
            )
        )
    }

    func testPreTransportOrNonIceFailuresAreNotSilentlyDeferred() {
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldDeferSignalingSendRecovery(
                isTransportEstablished: false,
                messageType: .iceCandidate
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldDeferSignalingSendRecovery(
                isTransportEstablished: true,
                messageType: .offer
            )
        )
    }

    func testTransportEstablishedFailuresSwitchToOnDemandSignaling() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldUseOnDemandSignalingAfterTransportFailure(
                isTransportEstablished: true
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldUseOnDemandSignalingAfterTransportFailure(
                isTransportEstablished: false
            )
        )
    }
}
