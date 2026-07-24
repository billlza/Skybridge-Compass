import Foundation
import XCTest
@testable import SkyBridgeCameraKit

final class SDPParserTests: XCTestCase {
    func testSkipsDisabledAndRecvOnlyVideoTracksAndSelectsUsableH264() throws {
        let endpoint = try RTSPEndpoint("rtsp://192.168.1.20:8554/live/")
        let sdp = """
        v=0
        m=video 0 RTP/AVP 96
        a=rtpmap:96 H264/90000
        a=control:disabled
        m=video 5004 RTP/AVP 97
        a=recvonly
        a=rtpmap:97 H264/90000
        a=control:receive-only
        m=video 5006 RTP/AVP 98
        a=sendonly
        a=rtpmap:98 H264/90000
        a=fmtp:98 packetization-mode=1;sprop-parameter-sets=Z0I=,aM4=
        a=control:trackID=2
        """
        let media = try SDPParser().parseH264Media(
            Data(sdp.utf8),
            baseURL: endpoint.url,
            endpoint: endpoint
        )
        XCTAssertEqual(media.payloadType, 98)
        XCTAssertEqual(media.packetizationMode, 1)
        XCTAssertEqual(media.controlURL.absoluteString, "rtsp://192.168.1.20:8554/live/trackID=2")
        XCTAssertEqual(media.sequenceParameterSets, [Data([0x67, 0x42])])
        XCTAssertEqual(media.pictureParameterSets, [Data([0x68, 0xCE])])
    }

    func testRejectsCrossOriginControlAndUnsupportedPacketizationMode() throws {
        let endpoint = try RTSPEndpoint("rtsp://192.168.1.20/live/")
        let crossOrigin = """
        v=0
        m=video 5004 RTP/AVP 96
        a=rtpmap:96 H264/90000
        a=control:rtsp://192.168.1.21/live/track
        """
        XCTAssertThrowsError(try SDPParser().parseH264Media(
            Data(crossOrigin.utf8), baseURL: endpoint.url, endpoint: endpoint
        ))

        let unsupportedMode = """
        v=0
        m=video 5004 RTP/AVP 96
        a=rtpmap:96 H264/90000
        a=fmtp:96 packetization-mode=2
        a=control:track
        """
        XCTAssertThrowsError(try SDPParser().parseH264Media(
            Data(unsupportedMode.utf8), baseURL: endpoint.url, endpoint: endpoint
        ))
    }

    func testSessionDirectionIsInheritedAndDuplicateMediaDirectionIsRejected() throws {
        let endpoint = try RTSPEndpoint("rtsp://192.168.1.20/live/")
        let inheritedReceiveOnly = """
        v=0
        a=recvonly
        m=video 5004 RTP/AVP 96
        a=rtpmap:96 H264/90000
        a=control:track
        """
        XCTAssertThrowsError(try SDPParser().parseH264Media(
            Data(inheritedReceiveOnly.utf8), baseURL: endpoint.url, endpoint: endpoint
        ))

        let duplicate = """
        v=0
        m=video 5004 RTP/AVP 96
        a=sendrecv
        a=sendonly
        a=rtpmap:96 H264/90000
        a=control:track
        """
        XCTAssertThrowsError(try SDPParser().parseH264Media(
            Data(duplicate.utf8), baseURL: endpoint.url, endpoint: endpoint
        ))
    }
}
