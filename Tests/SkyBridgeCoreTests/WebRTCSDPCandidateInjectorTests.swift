import XCTest
import SkyBridgeProtocolCore
@testable import SkyBridgeCore

final class WebRTCSDPCandidateInjectorTests: XCTestCase {
    func testInjectsCandidateIntoMatchingMidBeforeEndOfCandidatesPreservingCRLF() {
        let sdp = [
            "v=0",
            "o=- 0 0 IN IP4 127.0.0.1",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=mid:audio",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=mid:video",
            "a=end-of-candidates",
            ""
        ].joined(separator: "\r\n")
        let payload = WebRTCSignalingEnvelope.Payload(
            candidate: "candidate:1 1 udp 2122260223 192.0.2.1 54400 typ host",
            sdpMid: "video",
            sdpMLineIndex: nil
        )

        let rendered = WebRTCSDPCandidateInjector.injectLocalICECandidates([payload], into: sdp)

        XCTAssertTrue(rendered.contains("\r\n"))
        XCTAssertTrue(rendered.hasSuffix("\r\n"))
        XCTAssertTrue(
            rendered.contains(
                "a=mid:video\r\n" +
                "a=candidate:1 1 udp 2122260223 192.0.2.1 54400 typ host\r\n" +
                "a=end-of-candidates"
            )
        )
    }

    func testSkipsEmptyAndDuplicateCandidatesAndFallsBackToLastMediaSection() {
        let sdp = [
            "v=0",
            "m=audio 9 UDP/TLS/RTP/SAVPF 111",
            "a=mid:audio",
            "m=video 9 UDP/TLS/RTP/SAVPF 96",
            "a=mid:video"
        ].joined(separator: "\n")
        let candidate = WebRTCSignalingEnvelope.Payload(candidate: "a=candidate:2 1 udp 1 198.51.100.1 40000 typ host")
        let empty = WebRTCSignalingEnvelope.Payload(candidate: "   ")

        let rendered = WebRTCSDPCandidateInjector.injectLocalICECandidates([candidate, empty, candidate], into: sdp)

        XCTAssertEqual(
            rendered.components(separatedBy: "a=candidate:2 1 udp 1 198.51.100.1 40000 typ host").count - 1,
            1
        )
        XCTAssertTrue(
            rendered.contains("a=mid:video\n" + "a=candidate:2 1 udp 1 198.51.100.1 40000 typ host")
        )
    }
}
