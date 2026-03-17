import XCTest
@testable import SkyBridgeCore
import SkyBridgeAppleTransport

@MainActor
final class SignalingLifecycleContractTests: XCTestCase {
    func testOlderGenerationOpenAndBoundCannotOverrideCurrentHandle() {
        let manager = CrossNetworkConnectionManager()
        let currentHandle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-A",
            backend: .urlSession,
            generation: 2
        )
        manager.testingSeedSignalingState(
            sessionID: "SESSION-A",
            generation: 2,
            handle: currentHandle,
            health: .healthy,
            phase: .connecting
        )

        manager.handleSignalingLifecycleEvent(.init(
            handleId: .init(sessionId: "SESSION-A", backend: .native, generation: 1),
            phase: .socketOpen
        ))
        XCTAssertEqual(manager.testingCurrentSignalingHandle(), currentHandle)
        XCTAssertEqual(manager.signalingLifecyclePhase, .connecting)

        manager.handleSignalingLifecycleEvent(.init(
            handleId: .init(sessionId: "SESSION-A", backend: .native, generation: 1),
            phase: .bound
        ))
        XCTAssertEqual(manager.testingCurrentSignalingHandle(), currentHandle)
        XCTAssertEqual(manager.signalingLifecyclePhase, .connecting)
        XCTAssertEqual(manager.signalingHealth, .healthy)
    }

    func testPostTransportFatalFailureBecomesDegradedFatalWithoutDroppingReadiness() {
        let manager = CrossNetworkConnectionManager()
        let currentHandle = WebSocketSignalingClient.SignalingHandleID(
            sessionId: "SESSION-B",
            backend: .urlSession,
            generation: 4
        )
        manager.testingSeedSignalingState(
            sessionID: "SESSION-B",
            generation: 4,
            handle: currentHandle,
            health: .healthy,
            phase: .bound
        )
        manager.testingSetReadiness(.handshakeComplete(sessionId: "SESSION-B", negotiatedSuite: "X25519"))

        manager.handleSignalingLifecycleEvent(.init(
            handleId: currentHandle,
            phase: .failed,
            failureClass: .authBindRejected,
            errorDescription: "unauthorized"
        ))

        XCTAssertEqual(manager.signalingHealth, .degradedFatal)
        XCTAssertEqual(manager.readiness, .handshakeComplete(sessionId: "SESSION-B", negotiatedSuite: "X25519"))
        XCTAssertFalse(manager.testingCanPerformSignalingOperation(sessionID: "SESSION-B"))
    }
}
