import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class P2PScreenMirrorTests: XCTestCase {
    func testVideoFramePacketEncodeDecodeRoundTrip() {
        let packet = VideoFramePacket(
            frameSeq: 42,
            isKeyFrame: true,
            fragIndex: 0,
            fragCount: 1,
            payload: Data([0x01, 0x02, 0x03]),
            timestamp: 1234.5,
            orientation: .landscapeLeft
        )

        let encoded = packet.encode()
        guard let decoded = VideoFramePacket.decode(from: encoded) else {
            XCTFail("Failed to decode VideoFramePacket")
            return
        }

        XCTAssertEqual(decoded.frameSeq, packet.frameSeq)
        XCTAssertEqual(decoded.isKeyFrame, packet.isKeyFrame)
        XCTAssertEqual(decoded.fragIndex, packet.fragIndex)
        XCTAssertEqual(decoded.fragCount, packet.fragCount)
        XCTAssertEqual(decoded.payload, packet.payload)
        XCTAssertEqual(decoded.timestamp, packet.timestamp)
        XCTAssertEqual(decoded.orientation, packet.orientation)
    }

    func testVideoFramePacketRejectsShortHeader() {
        XCTAssertNil(VideoFramePacket.decode(from: Data()))
        XCTAssertNil(VideoFramePacket.decode(from: Data(repeating: 0, count: P2PConstants.videoFrameHeaderSize - 1)))
    }
}
