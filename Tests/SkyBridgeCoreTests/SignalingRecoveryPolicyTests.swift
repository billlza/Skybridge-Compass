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

    func testSignalingFailureClassificationStaysInPolicy() throws {
        let frame = try JSONDecoder().decode(
            WebSocketSignalingClient.SignalingServerFrame.self,
            from: Data(#"{"type":"error","error":"token expired","sessionId":"session-a"}"#.utf8)
        )

        XCTAssertEqual(
            CrossNetworkConnectionManager.classifySignalingFailure(from: frame),
            .tokenExpired
        )
        XCTAssertTrue(CrossNetworkConnectionManager.isFatalPreTransportFailure(.authBindRejected))
        XCTAssertTrue(CrossNetworkConnectionManager.isFatalPostTransportFailure(.protocolViolation))
        XCTAssertFalse(CrossNetworkConnectionManager.isFatalPreTransportFailure(.tokenExpired))
        XCTAssertFalse(CrossNetworkConnectionManager.isFatalPostTransportFailure(.transientNetwork))
    }
}
