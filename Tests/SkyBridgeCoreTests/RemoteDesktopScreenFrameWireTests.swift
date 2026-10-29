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

    func testBinaryScreenFrameWireDecodesNonZeroStartIndexSliceAndRejectsTruncation() throws {
        let h264IDR = Data([0x00, 0x00, 0x00, 0x01, 0x65, 0x88, 0x84])
        var imageStorage = Data([0xA0, 0xA1])
        imageStorage.append(h264IDR)
        let imageSlice = imageStorage[2..<imageStorage.endIndex]
        XCTAssertEqual(imageSlice.startIndex, 2)

        let encoded = RemoteDesktopScreenFrameWire.encode(
            width: 1280,
            height: 720,
            imageData: imageSlice,
            timestamp: 123.5,
            format: "h264",
            isSyncFrame: false,
            sequenceNumber: 77
        )
        var storage = Data([0xF0, 0xF1, 0xF2])
        storage.append(encoded)
        storage.append(0xF3)
        let encodedSlice = storage[3..<(3 + encoded.count)]

        XCTAssertEqual(encodedSlice.startIndex, 3)
        let decoded = try XCTUnwrap(RemoteDesktopScreenFrameWire.decodeIfPresent(encodedSlice))
        XCTAssertEqual(decoded.width, 1280)
        XCTAssertEqual(decoded.height, 720)
        XCTAssertEqual(decoded.imageData, h264IDR)
        XCTAssertEqual(decoded.isSyncFrame, true)
        XCTAssertEqual(decoded.sequenceNumber, 77)
        XCTAssertNil(RemoteDesktopScreenFrameWire.decodeIfPresent(encodedSlice.dropLast()))
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

    func testScreenChunkEnvelopeDecodesNonZeroStartIndexSliceAndRejectsTruncation() throws {
        let payload = Data([0x10, 0x20, 0x30, 0x40])
        let encoded = try RemoteDesktopScreenFrameWire.encodeChunkEnvelope(
            frameId: 90,
            chunkIndex: 0,
            chunkCount: 1,
            totalBytes: payload.count,
            chunkOffset: 0,
            payload: payload
        )
        var storage = Data([0xA0, 0xA1])
        storage.append(encoded)
        storage.append(0xA2)
        let encodedSlice = storage[2..<(2 + encoded.count)]

        XCTAssertEqual(encodedSlice.startIndex, 2)
        XCTAssertTrue(RemoteDesktopScreenFrameWire.startsWithChunkMagic(encodedSlice))
        let decoded = try XCTUnwrap(
            RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(encodedSlice)
        )
        XCTAssertEqual(decoded.frameId, 90)
        XCTAssertEqual(decoded.payload, payload)
        XCTAssertNil(
            RemoteDesktopScreenFrameWire.decodeChunkEnvelopeIfPresent(encodedSlice.dropLast())
        )
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

    func testHEVCDecoderBootstrapRequiresParameterSetsAndIRAP() {
        let hevcIRAPOnly = Data([0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x88])
        XCTAssertFalse(
            RemoteDesktopScreenFrameWire.containsDecoderBootstrapFrame(
                format: "hevc",
                imageData: hevcIRAPOnly,
                advertisedSyncFrame: true
            )
        )

        let hevcBootstrap = Data([
            0x00, 0x00, 0x00, 0x01, 0x40, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x42, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x44, 0x01,
            0x00, 0x00, 0x00, 0x01, 0x26, 0x01, 0x88
        ])
        XCTAssertTrue(
            RemoteDesktopScreenFrameWire.containsDecoderBootstrapFrame(
                format: "hevc",
                imageData: hevcBootstrap,
                advertisedSyncFrame: false
            )
        )
    }

    func testHEVCSyncAndBootstrapRejectMalformedOneByteNALHeaders() {
        let malformedIRAP = Data([0x00, 0x00, 0x00, 0x01, 0x26])
        XCTAssertFalse(
            RemoteDesktopScreenFrameWire.containsSyncFrame(
                format: "hevc",
                imageData: malformedIRAP,
                advertisedSyncFrame: true
            )
        )

        let malformedBootstrap = Data([
            0x00, 0x00, 0x00, 0x01, 0x40,
            0x00, 0x00, 0x00, 0x01, 0x42,
            0x00, 0x00, 0x00, 0x01, 0x44,
            0x00, 0x00, 0x00, 0x01, 0x26
        ])
        XCTAssertFalse(
            RemoteDesktopScreenFrameWire.containsDecoderBootstrapFrame(
                format: "hevc",
                imageData: malformedBootstrap,
                advertisedSyncFrame: true
            )
        )
    }

    func testAudioChunkWireDecodesNonZeroStartIndexSliceAndRejectsTruncation() throws {
        let payload = RemoteDesktopAudioChunkPayload(
            encoding: .aacLC,
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 1_024,
            packetCount: 1,
            packetDescriptions: [
                .init(startOffset: 0, variableFramesInPacket: 1_024, dataByteSize: 4)
            ],
            magicCookie: Data([0x11, 0x22]),
            sequenceNumber: 55,
            sentAt: 123.5,
            data: Data([0xDE, 0xAD, 0xBE, 0xEF])
        )
        let encoded = RemoteDesktopAudioChunkWire.encode(payload)
        var storage = Data([0xB0, 0xB1, 0xB2, 0xB3])
        storage.append(encoded)
        storage.append(0xB4)
        let encodedSlice = storage[4..<(4 + encoded.count)]

        XCTAssertEqual(encodedSlice.startIndex, 4)
        XCTAssertEqual(RemoteDesktopAudioChunkWire.decodeIfPresent(encodedSlice), payload)
        XCTAssertNil(RemoteDesktopAudioChunkWire.decodeIfPresent(encodedSlice.dropLast()))
    }
}
