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

    func testDescribeEnvelopeSummarizesPayloadWithoutLeakingSensitiveIdentifiersOrAuthToken() {
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
        XCTAssertTrue(offerSummary.contains("session_ref=ref:"))
        XCTAssertTrue(offerSummary.contains("type=offer"))
        XCTAssertTrue(offerSummary.contains("from_ref=ref:"))
        XCTAssertTrue(offerSummary.contains("to_ref=ref:"))
        XCTAssertTrue(offerSummary.contains("auth=1"))
        XCTAssertTrue(offerSummary.contains("media=1 hasVideo=true videoDir=sendonly candidates total=1"))
        XCTAssertFalse(offerSummary.contains("session-1"))
        XCTAssertFalse(offerSummary.contains("from=ios"))
        XCTAssertFalse(offerSummary.contains("to=mac"))
        XCTAssertFalse(offerSummary.contains("secret-token"))

        let iceSummary = CrossNetworkWebRTCTraceDescription.describeEnvelope(ice)
        XCTAssertTrue(iceSummary.contains("session_ref=ref:"))
        XCTAssertTrue(iceSummary.contains("type=iceCandidate"))
        XCTAssertTrue(iceSummary.contains("from_ref=ref:"))
        XCTAssertTrue(iceSummary.contains("to_ref=-"))
        XCTAssertTrue(iceSummary.contains("auth=1 kind=relay"))
        XCTAssertFalse(iceSummary.contains("session-1"))
        XCTAssertFalse(iceSummary.contains("from=mac"))
        XCTAssertFalse(iceSummary.contains("secret-token"))
    }

    func testTraceRedactionSanitizesKnownAssignments() {
        let raw = "local-offer session=session-secret from=ios-device to=mac-device peer=peer-device token=secret-token relay=10.0.0.5:3478 untouched=value"

        let redacted = SkyBridgeTraceRedaction.redactKnownAssignments(in: raw)

        XCTAssertTrue(redacted.contains("session_ref=ref:"))
        XCTAssertTrue(redacted.contains("from_ref=ref:"))
        XCTAssertTrue(redacted.contains("to_ref=ref:"))
        XCTAssertTrue(redacted.contains("peer_ref=ref:"))
        XCTAssertTrue(redacted.contains("token_ref=ref:"))
        XCTAssertTrue(redacted.contains("relay_ref=ref:"))
        XCTAssertTrue(redacted.contains("untouched=value"))
        XCTAssertFalse(redacted.contains("session-secret"))
        XCTAssertFalse(redacted.contains("ios-device"))
        XCTAssertFalse(redacted.contains("mac-device"))
        XCTAssertFalse(redacted.contains("peer-device"))
        XCTAssertFalse(redacted.contains("secret-token"))
        XCTAssertFalse(redacted.contains("10.0.0.5:3478"))
    }

    func testMediaDiagnosticSanitizesSensitiveFieldsAndUnsupportedValues() {
        let payload = SkyBridgeTraceRedaction.sanitizedMediaDiagnosticFields(
            [
                "kind": "visibleNativeRenderFPS",
                "session": "session-secret",
                "session_id": "session-secret",
                "relay": "10.0.0.5:3478",
                "trackId": "track-secret",
                "viewerDisplayFPS": 60.0,
                "relayTokenPresent": true,
                "rawPath": "/Users/bill/private/status.log",
                "nested": ["token": "secret"]
            ],
            timestamp: "2026-07-07T00:00:00.000Z"
        )

        XCTAssertEqual(payload["schema_version"] as? Int, 1)
        XCTAssertEqual(payload["timestamp"] as? String, "2026-07-07T00:00:00.000Z")
        XCTAssertEqual(payload["kind"] as? String, "visibleNativeRenderFPS")
        XCTAssertEqual(payload["viewerDisplayFPS"] as? Double, 60.0)
        XCTAssertEqual(payload["relayTokenPresent"] as? Bool, true)
        XCTAssertTrue((payload["session_ref"] as? String)?.hasPrefix("ref:") == true)
        XCTAssertTrue((payload["relay_ref"] as? String)?.hasPrefix("ref:") == true)
        XCTAssertTrue((payload["track_ref"] as? String)?.hasPrefix("ref:") == true)
        XCTAssertTrue((payload["rawPath_ref"] as? String)?.hasPrefix("ref:") == true)
        XCTAssertEqual(payload["nested_redacted"] as? String, "unsupported_non_scalar")
        XCTAssertNil(payload["session"])
        XCTAssertNil(payload["session_id"])
        XCTAssertNil(payload["relay"])
        XCTAssertNil(payload["trackId"])
        XCTAssertNil(payload["rawPath"])
        XCTAssertFalse(String(describing: payload).contains("session-secret"))
        XCTAssertFalse(String(describing: payload).contains("10.0.0.5:3478"))
        XCTAssertFalse(String(describing: payload).contains("/Users/bill/private/status.log"))
        XCTAssertFalse(String(describing: payload).contains("secret"))
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
