import XCTest
@testable import SkyBridgeCore

final class RemoteDesktopScreenFrameWireTests: XCTestCase {
    func testBinaryScreenFrameWireRoundTripsRawPayloadWithoutTrustingAdvertisedVideoSync() {
        let payload = Data((0..<512).map { UInt8($0 % 251) })
        let encoded = RemoteDesktopScreenFrameWire.encode(
            width: 1206,
            height: 779,
            imageData: payload,
            timestamp: 1_710_000_123.456789,
            format: "h264",
            isSyncFrame: true
        )
        let decoded = RemoteDesktopScreenFrameWire.decodeIfPresent(encoded)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.width, 1206)
        XCTAssertEqual(decoded?.height, 779)
        XCTAssertEqual(decoded?.format, "h264")
        XCTAssertEqual(decoded?.isSyncFrame, false)
        XCTAssertEqual(decoded?.imageData, payload)
        XCTAssertEqual(decoded?.timestamp ?? 0, 1_710_000_123.456789, accuracy: 0.000_001)
        XCTAssertNil(decoded?.sequenceNumber)
    }

    func testBinaryScreenFrameWireV2RoundTripsFrameSequenceNumber() {
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x88])
        let encoded = RemoteDesktopScreenFrameWire.encode(
            width: 2056,
            height: 1329,
            imageData: payload,
            timestamp: 1_710_000_123.5,
            format: "hevc",
            isSyncFrame: false,
            sequenceNumber: 9_223_372_036_854
        )

        let decoded = RemoteDesktopScreenFrameWire.decodeIfPresent(encoded)

        XCTAssertEqual(decoded?.format, "hevc")
        XCTAssertEqual(decoded?.isSyncFrame, true)
        XCTAssertEqual(decoded?.imageData, payload)
        XCTAssertEqual(decoded?.sequenceNumber, 9_223_372_036_854)
        XCTAssertEqual(encoded.count, 36 + payload.count)
    }

    func testBinaryScreenFrameWireIsSubstantiallyLeanerThanLegacyJSONEnvelope() throws {
        struct LegacyRemoteMessage: Codable {
            let type: String
            let payload: Data
        }

        let payload = Data(repeating: 0xAB, count: 48_000)
        struct LegacyScreenData: Codable {
            let width: Int
            let height: Int
            let imageData: Data
            let timestamp: Double
            let format: String?
        }

        let binaryEncoded = RemoteDesktopScreenFrameWire.encode(
            width: 1206,
            height: 779,
            imageData: payload,
            timestamp: 1_710_000_123.25,
            format: "h264"
        )
        let legacyInner = try JSONEncoder().encode(
            LegacyScreenData(
                width: 1206,
                height: 779,
                imageData: payload,
                timestamp: 1_710_000_123.25,
                format: "h264"
            )
        )
        let legacyOuter = try JSONEncoder().encode(
            LegacyRemoteMessage(type: "screenData", payload: legacyInner)
        )

        XCTAssertLessThan(binaryEncoded.count, legacyOuter.count)
        XCTAssertLessThan(Double(binaryEncoded.count), Double(legacyOuter.count) * 0.7)
    }

    func testBinaryScreenFrameWireRejectsJSONPayload() throws {
        let legacyEnvelope = try JSONEncoder().encode(["type": "screenData"])

        XCTAssertNil(RemoteDesktopScreenFrameWire.decodeIfPresent(legacyEnvelope))
    }

    func testScreenChunkEnvelopeRoundTripsStrictMetadata() throws {
        let payload = Data((0..<1024).map { UInt8($0 % 251) })
        let encoded = try RemoteDesktopScreenFrameWire.encodeChunkEnvelope(
            frameId: 42,
            chunkIndex: 1,
            chunkCount: 3,
            totalBytes: 3_000,
            chunkOffset: 1_024,
            payload: payload
        )

        XCTAssertTrue(RemoteDesktopScreenFrameWire.startsWithChunkMagic(encoded))
        let decoded = try XCTUnwrap(RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(encoded))
        XCTAssertEqual(decoded.frameId, 42)
        XCTAssertEqual(decoded.chunkIndex, 1)
        XCTAssertEqual(decoded.chunkCount, 3)
        XCTAssertEqual(decoded.totalBytes, 3_000)
        XCTAssertEqual(decoded.chunkOffset, 1_024)
        XCTAssertEqual(decoded.payload, payload)
    }

    func testScreenChunkEnvelopeRejectsCorruptFlagMetadata() throws {
        var encoded = try RemoteDesktopScreenFrameWire.encodeChunkEnvelope(
            frameId: 7,
            chunkIndex: 0,
            chunkCount: 2,
            totalBytes: 16,
            chunkOffset: 0,
            payload: Data(repeating: 0xA5, count: 8)
        )
        encoded[5] = 0

        XCTAssertNil(RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(encoded))
    }

    func testBinaryScreenFrameWirePromotesH264IDRToSyncEvenWhenAdvertisedFlagIsFalse() {
        let payload = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84])
        let encoded = RemoteDesktopScreenFrameWire.encode(
            width: 1280,
            height: 720,
            imageData: payload,
            timestamp: 123,
            format: "h264",
            isSyncFrame: false
        )

        let decoded = RemoteDesktopScreenFrameWire.decodeIfPresent(encoded)

        XCTAssertEqual(decoded?.isSyncFrame, true)
    }

    func testBinaryScreenFrameWireDoesNotTrustAdvertisedHEVCSyncWithoutIRAPNAL() {
        let predictiveHEVC = Data([0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x88])
        let encoded = RemoteDesktopScreenFrameWire.encode(
            width: 2056,
            height: 1329,
            imageData: predictiveHEVC,
            timestamp: 123,
            format: "hevc",
            isSyncFrame: true
        )

        let decoded = RemoteDesktopScreenFrameWire.decodeIfPresent(encoded)

        XCTAssertEqual(decoded?.isSyncFrame, false)
    }

    func testBinaryScreenFrameWireDetectsHEVCIRAPWhenAdvertisedFlagIsFalse() {
        let hevcIRAP = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x88])
        let encoded = RemoteDesktopScreenFrameWire.encode(
            width: 2056,
            height: 1329,
            imageData: hevcIRAP,
            timestamp: 123,
            format: "hevc",
            isSyncFrame: false
        )

        let decoded = RemoteDesktopScreenFrameWire.decodeIfPresent(encoded)

        XCTAssertEqual(decoded?.isSyncFrame, true)
    }
}
