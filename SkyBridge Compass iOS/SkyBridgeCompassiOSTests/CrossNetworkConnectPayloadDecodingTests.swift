import XCTest
@testable import SkyBridgeCompass_iOS

@MainActor
@available(iOS 17.0, *)
final class CrossNetworkConnectPayloadDecodingTests: XCTestCase {
    func testDecodeConnectPayloadSupportsURLSafeUnpaddedPayloads() {
        let original = Data((0..<64).map { index in
            [UInt8](arrayLiteral: 0xfb, 0xff, 0xef, 0xfa)[index % 4]
        })
        let encoded = original.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        XCTAssertTrue(encoded.contains("-") || encoded.contains("_"))
        XCTAssertEqual(CrossNetworkWebRTCManager.decodeConnectPayload(encoded), original)
    }

    func testDecodeConnectPayloadRejectsMalformedCharacters() {
        XCTAssertNil(CrossNetworkWebRTCManager.decodeConnectPayload("abc$%^"))
    }
}
