import XCTest
@testable import SkyBridgeCore

@available(macOS 14.0, iOS 17.0, *)
final class CrossNetworkConnectPayloadParserTests: XCTestCase {
    func testExtractPayloadAcceptsPathAndQueryConnectLinks() {
        XCTAssertEqual(
            CrossNetworkConnectPayloadParser.extractPayload(from: " skybridge://connect/abc123 "),
            "abc123"
        )
        XCTAssertEqual(
            CrossNetworkConnectPayloadParser.extractPayload(from: "skybridge://connect?data=abc123"),
            "abc123"
        )
    }

    func testExtractPayloadRejectsNonConnectPayloads() {
        XCTAssertNil(CrossNetworkConnectPayloadParser.extractPayload(from: ""))
        XCTAssertNil(CrossNetworkConnectPayloadParser.extractPayload(from: #"{"type":"device_pairing"}"#))
        XCTAssertNil(CrossNetworkConnectPayloadParser.extractPayload(from: "https://example.com/connect/abc123"))
    }
}
