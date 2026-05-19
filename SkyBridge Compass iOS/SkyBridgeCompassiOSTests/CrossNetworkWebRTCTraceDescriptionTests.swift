import XCTest
@testable import SkyBridgeCompass_iOS

final class CrossNetworkWebRTCTraceDescriptionTests: XCTestCase {
    func testDescribeCandidateKindClassifiesKnownTypes() {
        XCTAssertEqual(
            CrossNetworkWebRTCTraceDescription.describeCandidateKind("candidate:1 1 udp 1 10.0.0.1 123 typ relay"),
            "relay"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCTraceDescription.describeCandidateKind("candidate:1 1 udp 1 10.0.0.1 123 typ srflx"),
            "srflx"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCTraceDescription.describeCandidateKind("candidate:1 1 udp 1 10.0.0.1 123 typ prflx"),
            "prflx"
        )
        XCTAssertEqual(
            CrossNetworkWebRTCTraceDescription.describeCandidateKind("candidate:1 1 udp 1 10.0.0.1 123 typ host"),
            "host"
        )
        XCTAssertEqual(CrossNetworkWebRTCTraceDescription.describeCandidateKind(nil), "unknown")
        XCTAssertEqual(CrossNetworkWebRTCTraceDescription.describeCandidateKind("candidate-without-type"), "unknown")
    }

    func testDescribeSDPCandidatesCountsMediaSectionsVideoDirectionAndCandidateTypes() {
        let sdp = """
        v=0
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=sendrecv
        a=candidate:1 1 udp 1 10.0.0.1 10000 typ host
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=recvonly
        a=candidate:2 1 udp 1 203.0.113.10 20000 typ srflx
        a=candidate:3 1 udp 1 198.51.100.10 30000 typ relay
        a=candidate:4 1 udp 1 192.0.2.10 40000 typ prflx
        """

        XCTAssertEqual(
            CrossNetworkWebRTCTraceDescription.describeSDPCandidates(sdp),
            "media=2 hasVideo=true videoDir=recvonly candidates total=4 host=1 srflx=1 relay=1 prflx=1"
        )
    }

    func testDescribeEnvelopeSummarizesPayloadWithoutLeakingAuthToken() {
        let sdp = """
        v=0
        m=video 9 UDP/TLS/RTP/SAVPF 96
        a=sendonly
        a=candidate:1 1 udp 1 10.0.0.1 10000 typ host
        """
        let offer = WebRTCSignalingEnvelope(
            sessionId: "session-1",
            from: "ios",
            to: "mac",
            type: .offer,
            payload: WebRTCSignalingEnvelope.Payload(sdp: sdp),
            authToken: "secret-token"
        )
        let ice = WebRTCSignalingEnvelope(
            sessionId: "session-1",
            from: "mac",
            type: .iceCandidate,
            payload: WebRTCSignalingEnvelope.Payload(candidate: "candidate:1 1 udp 1 10.0.0.1 10000 typ relay"),
            authToken: "secret-token"
        )

        let offerSummary = CrossNetworkWebRTCTraceDescription.describeEnvelope(offer)
        XCTAssertTrue(offerSummary.contains("session=session-1 type=offer from=ios to=mac auth=1"))
        XCTAssertTrue(offerSummary.contains("media=1 hasVideo=true videoDir=sendonly candidates total=1"))
        XCTAssertFalse(offerSummary.contains("secret-token"))

        let iceSummary = CrossNetworkWebRTCTraceDescription.describeEnvelope(ice)
        XCTAssertTrue(iceSummary.contains("session=session-1 type=iceCandidate from=mac to=- auth=1 kind=relay"))
        XCTAssertFalse(iceSummary.contains("secret-token"))
    }

    func testSmokeTraceTokenRemovesWhitespaceAndLimitsLength() {
        let token = CrossNetworkWebRTCTraceDescription.smokeTraceToken(
            " failure reason\nwith spaces\tand/symbols " + String(repeating: "x", count: 200)
        )

        XCTAssertFalse(token.contains(" "))
        XCTAssertFalse(token.contains("\n"))
        XCTAssertFalse(token.contains("/"))
        XCTAssertLessThanOrEqual(token.count, 120)
    }
}
