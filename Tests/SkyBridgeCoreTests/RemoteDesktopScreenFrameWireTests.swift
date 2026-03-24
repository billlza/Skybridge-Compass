import XCTest
@testable import SkyBridgeCore

final class RemoteDesktopScreenFrameWireTests: XCTestCase {
    func testBinaryScreenFrameWireRoundTripsRawPayload() {
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
        XCTAssertEqual(decoded?.isSyncFrame, true)
        XCTAssertEqual(decoded?.imageData, payload)
        XCTAssertEqual(decoded?.timestamp ?? 0, 1_710_000_123.456789, accuracy: 0.000_001)
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
}
