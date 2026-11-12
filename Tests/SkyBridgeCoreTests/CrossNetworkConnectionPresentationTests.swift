import XCTest
@testable import SkyBridgeCore

@MainActor
final class CrossNetworkConnectionPresentationTests: XCTestCase {
    private func connectedManager(_ sessionID: String) -> (CrossNetworkConnectionManager, WebRTCSession) {
        let session = WebRTCSession(sessionId: sessionID, localDeviceId: "local-test-device", role: .answerer,
            ice: .init(stunURL: "", turnURLs: [], turnUsername: "", turnPassword: ""))
        let manager = CrossNetworkConnectionManager()
        manager.currentConnection = RemoteConnection(id: sessionID, deviceName: "Test peer", transport: .webrtc(session))
        manager.connectionStatus = .connected
        manager.testingSetReadiness(.handshakeComplete(sessionId: sessionID, negotiatedSuite: "ML-KEM-768"))
        return (manager, session)
    }

    func testRetiredCurrentSessionCannotRemainVisiblyConnected() {
        let (manager, session) = connectedManager("retired-session")
        defer { session.close() }
        manager.testingCleanupWebRTCSession("retired-session")
        XCTAssertNil(manager.currentConnection)
        XCTAssertEqual(manager.readiness, .idle)
        guard case .idle = manager.connectionStatus else {
            return XCTFail("Retiring the current WebRTC owner must retire its connected presentation")
        }
    }

    func testRetiringAnotherSessionPreservesTheCurrentPresentation() {
        let (manager, session) = connectedManager("current-session")
        defer { session.close() }
        manager.testingCleanupWebRTCSession("old-session")
        XCTAssertEqual(manager.currentConnection?.id, "current-session")
        XCTAssertEqual(manager.readiness, .handshakeComplete(sessionId: "current-session", negotiatedSuite: "ML-KEM-768"))
        guard case .connected = manager.connectionStatus else {
            return XCTFail("An old session must not clear another owner's presentation")
        }
    }

    func testRetiringFailedSessionPreservesItsFailureReason() {
        let (manager, session) = connectedManager("failed-session")
        defer { session.close() }
        manager.connectionStatus = .failed("controlled protocol failure")
        manager.testingCleanupWebRTCSession("failed-session")
        XCTAssertNil(manager.currentConnection)
        guard case .failed(let reason) = manager.connectionStatus else {
            return XCTFail("Cleanup must retain the original reported failure")
        }
        XCTAssertEqual(reason, "controlled protocol failure")
    }
}
