import XCTest
@testable import SkyBridgeCore

final class CrossNetworkBase64URLDecodingTests: XCTestCase {
    func testDecodeBase64PayloadSupportsURLSafeUnpaddedPayloads() {
        let original = Data((0..<64).map { index in
            [UInt8](arrayLiteral: 0xfb, 0xff, 0xef, 0xfa)[index % 4]
        })
        let encoded = original.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        XCTAssertTrue(encoded.contains("-") || encoded.contains("_"))
        XCTAssertEqual(CrossNetworkConnectionManager.decodeBase64Payload(encoded), original)
    }

    func testDecodeBase64PayloadRejectsMalformedCharacters() {
        XCTAssertNil(CrossNetworkConnectionManager.decodeBase64Payload("abc$%^"))
    }
}
