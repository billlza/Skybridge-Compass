#if canImport(WebRTC)
import XCTest
import WebRTC
@testable import SkyBridgeCore

@MainActor
final class WebRTCSelectedCandidateEventTests: XCTestCase {
    func testSelectedPairEventSuppliesAddressWhenStatisticsHaveNoCandidateAddress() async throws {
        let session = try makeSession("selected-address")
        defer { session.close() }
        let peer = try XCTUnwrap(session.testingPeerConnection)
        emitSelection(session, peer: peer, address: "192.0.2.42")
        let address = await session.currentSelectedRemoteCandidateAddress()
        XCTAssertEqual(address, "192.0.2.42")
    }

    func testSelectionReplacementInvalidationAndLateCallbackCannotReuseOldAddress() async throws {
        let session = try makeSession("selected-lifecycle")
        defer { session.close() }
        let peer = try XCTUnwrap(session.testingPeerConnection)
        emitSelection(session, peer: peer, address: "192.0.2.42")
        emitSelection(session, peer: peer, address: "2001:db8::42")
        let replacement = await session.currentSelectedRemoteCandidateAddress()
        XCTAssertEqual(replacement, "2001:db8::42")
        session.peerConnection(peer, didChange: RTCIceConnectionState.disconnected)
        let disconnected = await session.currentSelectedRemoteCandidateAddress()
        XCTAssertNil(disconnected)
        session.close()
        emitSelection(session, peer: peer, address: "192.0.2.99")
        let closed = await session.currentSelectedRemoteCandidateAddress()
        XCTAssertNil(closed)
    }

    func testAnotherPeerConnectionCannotReplaceCurrentSelectedAddress() async throws {
        let session = try makeSession("selected-owner")
        let other = try makeSession("other-owner")
        defer { session.close(); other.close() }
        let peer = try XCTUnwrap(session.testingPeerConnection)
        let wrongPeer = try XCTUnwrap(other.testingPeerConnection)
        emitSelection(session, peer: peer, address: "192.0.2.42")
        emitSelection(session, peer: wrongPeer, address: "192.0.2.99")
        let address = await session.currentSelectedRemoteCandidateAddress()
        XCTAssertEqual(address, "192.0.2.42")
    }

    func testMalformedOrUnspecifiedNewCandidateClearsEarlierAddress() async throws {
        let session = try makeSession("selected-invalid")
        defer { session.close() }
        let peer = try XCTUnwrap(session.testingPeerConnection)
        for address in ["0.0.0.0", "::", "invalid\naddress"] {
            emitSelection(session, peer: peer, address: "192.0.2.42")
            emitSelection(session, peer: peer, address: address)
            let observed = await session.currentSelectedRemoteCandidateAddress()
            XCTAssertNil(observed)
        }
    }

    private func emitSelection(_ session: WebRTCSession, peer: RTCPeerConnection, address: String) {
        let delegate: any RTCPeerConnectionDelegate = session
        // Native libwebrtc selected-pair events carry a transport name and -1
        // for mLineIndex. They are observations, not trickle candidate inputs.
        let local = RTCIceCandidate(sdp: "candidate:local 1 udp 100 192.0.2.10 12345 typ host",
                                    sdpMLineIndex: -1, sdpMid: "0")
        let remote = RTCIceCandidate(sdp: "candidate:remote 1 udp 100 \(address) 12345 typ prflx",
                                     sdpMLineIndex: -1, sdpMid: "0")
        delegate.peerConnection?(peer, didChangeLocalCandidate: local, remoteCandidate: remote,
                                 lastReceivedMs: 0, changeReason: "candidate pair selected")
    }

    private func makeSession(_ id: String) throws -> WebRTCSession {
        let session = WebRTCSession(
            sessionId: id, localDeviceId: "selected-event-test", role: .answerer,
            ice: .init(stunURL: "stun:127.0.0.1:3478", turnURLs: [], turnUsername: "", turnPassword: "")
        )
        try session.start()
        return session
    }
}
#endif
