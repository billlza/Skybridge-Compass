import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class CrossNetworkWebRTCHandshakeBootstrapTests: XCTestCase {
    func testInitialWebRTCHandshakeStartsFromOffererOnly() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldInitiateInitialWebRTCHandshake(role: .offerer)
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldInitiateInitialWebRTCHandshake(role: .answerer)
        )
    }

    func testInitialWebRTCHandshakeUsesClassicForAuthorityBoundQRAndCodeSessions() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "qr-session",
                authorityBoundBootstrapSessionIds: ["qr-session"],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: nil
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "code-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: nil,
                activeConnectionCodeSessionID: "code-session"
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "answerer-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .ed25519,
                activeConnectionCodeSessionID: nil
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldUseClassicAuthorityBootstrapForInitialWebRTCHandshake(
                sessionID: "pqc-session",
                authorityBoundBootstrapSessionIds: [],
                expectedRemoteAuthorityAlgorithm: .mlDSA65,
                activeConnectionCodeSessionID: nil
            )
        )
    }

    func testInitialWebRTCHandshakePeerResolutionPrefersConcreteRemoteDeviceId() {
        let resolution = CrossNetworkConnectionManager.initialWebRTCHandshakePeerResolution(
            expectedRemoteDeviceId: nil,
            learnedRemoteDeviceId: "E0715A9A-D0D3-47E6-B353-DE0A30293E1F",
            endpointDescription: "webrtc:session-1"
        )

        XCTAssertEqual(resolution.resolvedPeerDeviceId, "E0715A9A-D0D3-47E6-B353-DE0A30293E1F")
        XCTAssertEqual(
            resolution.candidateIds,
            ["E0715A9A-D0D3-47E6-B353-DE0A30293E1F", "webrtc:session-1"]
        )
    }

    func testStrictPQCHandshakeWaitsUntilRemoteIdentityAndTrustedKEMAreReady() {
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: nil,
                hasTrustedPeerKEM: false
            )
        )
        XCTAssertTrue(
            CrossNetworkConnectionManager.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: "peer-1",
                hasTrustedPeerKEM: false
            )
        )
        XCTAssertFalse(
            CrossNetworkConnectionManager.shouldWaitForStrictPQCInitialWebRTCHandshake(
                strictPQCRequested: true,
                resolvedPeerDeviceId: "peer-1",
                hasTrustedPeerKEM: true
            )
        )
    }
}
