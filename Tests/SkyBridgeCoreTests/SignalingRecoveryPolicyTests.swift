import XCTest
@testable import SkyBridgeCore

@MainActor
final class SignalingRecoveryPolicyTests: XCTestCase {
    func testPostTransportSignalingFailuresDeferToOnDemandRecoveryExceptLeave() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                messageType: .iceCandidate
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                messageType: .offer
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: true,
                messageType: .leave
            )
        )
    }

    func testPreTransportFailuresAreNotSilentlyDeferred() {
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldDeferSignalingSendRecovery(
                isHandshakeComplete: false,
                messageType: .iceCandidate
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
