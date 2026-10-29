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

    func testVideoFramePacketDecodesNonZeroStartIndexSlice() throws {
        let packet = VideoFramePacket(
            frameSeq: 99,
            isKeyFrame: false,
            fragIndex: 1,
            fragCount: 2,
            payload: Data([0xAA, 0xBB]),
            timestamp: 42.25,
            orientation: .landscapeRight
        )
        var storage = Data(repeating: 0xEE, count: 5)
        storage.append(packet.encode())
        let slice = storage[5..<storage.endIndex]

        XCTAssertEqual(slice.startIndex, 5)
        let decoded = try XCTUnwrap(VideoFramePacket.decode(from: slice))
        XCTAssertEqual(decoded.frameSeq, packet.frameSeq)
        XCTAssertEqual(decoded.fragIndex, packet.fragIndex)
        XCTAssertEqual(decoded.fragCount, packet.fragCount)
        XCTAssertEqual(decoded.payload, packet.payload)
        XCTAssertEqual(decoded.timestamp, packet.timestamp)
        XCTAssertEqual(decoded.orientation, packet.orientation)
    }

    func testVideoFramePacketRejectsInvalidSemanticHeaderFields() {
        let valid = VideoFramePacket(
            frameSeq: 7,
            isKeyFrame: true,
            fragIndex: 0,
            fragCount: 1,
            payload: Data([0x01]),
            timestamp: 1,
            orientation: .portrait
        ).encode()

        func replacingUInt16(_ value: UInt16, at offset: Int) -> Data {
            var data = valid
            var encoded = value.bigEndian
            withUnsafeBytes(of: &encoded) { bytes in
                data.replaceSubrange(offset..<(offset + 2), with: bytes)
            }
            return data
        }

        XCTAssertNil(VideoFramePacket.decode(from: replacingUInt16(0, at: 10)))
        XCTAssertNil(VideoFramePacket.decode(from: replacingUInt16(1, at: 8)))
        XCTAssertNil(VideoFramePacket.decode(from: replacingUInt16(0x000E, at: 12)))
        XCTAssertNil(VideoFramePacket.decode(from: replacingUInt16(1, at: 22)))

        var nonFiniteTimestamp = valid
        var nanBits = Double.nan.bitPattern.bigEndian
        withUnsafeBytes(of: &nanBits) { bytes in
            nonFiniteTimestamp.replaceSubrange(14..<22, with: bytes)
        }
        XCTAssertNil(VideoFramePacket.decode(from: nonFiniteTimestamp))
    }
}
